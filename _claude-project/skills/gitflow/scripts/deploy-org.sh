#!/bin/bash
# gitflow deploy in an org repo: make the branch's Terraform PR real, then land it.
# deploy.sh hands over to this in a repo holding infrastructure — always in an org
# repo, from a PR branch in a combo repo (repo_kind.sh). Run from the repository root,
# on the PR's branch:
#
#   deploy-org.sh [<deploy.sh release arguments>]
#
# In order, and each step stops the run on failure:
#   1. The branch has an open PR against main, a clean tree, nothing unpushed, and
#      everything main has — so what is applied is exactly what will land.
#   2. CI on the PR is green — the real gate (wait-for-pr-ready.sh).
#   3. Every root the branch changes (changed-roots.sh) is planned afresh, and each
#      plan must do exactly what the PR body's plan block for that root shows
#      (plan-summary.sh) — or nothing at all: a root that is already live (a
#      re-run after a merge that did not finish) has nothing left to apply. Any
#      other difference — someone changed AWS, another PR landed — stops here with
#      the difference, before anything is applied.
#   4. Every root's fresh plan is applied.
#   5. merge.sh squash-merges the PR, so main only ever holds what is live.
#   6. The infrastructure reference is regenerated from the new state and committed
#      straight to main, as a release commits its changelog — a commit of generated
#      docs waits on no CI run.
#   7. The issues the PR closes (its `Closes #N` line) move to the board's deploy
#      status, as every /deploy moves what it shipped.
#   8. In a combo repo, a PR that also changes the app — any file outside
#      infra/terraform/, project-documentation/, .claude/ and Markdown — is released
#      straight from main by deploy.sh with the arguments this run was given, the same
#      release /deploy on main cuts. Step 7 is then the release's, not this script's.
#      With no release arguments, it stops after the merge and says to /deploy on main.
#
# Typing /deploy is the person's approval of the plan the PR shows; this script
# applies nothing else.
#
# Exit codes:
#   2  no Terraform root changed (docs go to main with /ship-main)
#   3  on main, or detached HEAD
#   4  dirty working tree
#   5  the branch has commits not pushed to origin
#   8  gh, jq, terraform or dot (Graphviz, for the reference) missing
#   9  no open PR for this branch
#  11  CI failed, or the readiness wait did not finish
#  26  a fresh plan differs from the PR's plan — nothing applied
#  27  a plan could not be made — nothing applied
#  28  an apply failed — the roots named as applied are live; nothing merged
#  29  applied and merged, but the reference could not be regenerated or pushed to main
#  30  the PR is stacked on another branch — deploy that one first
#  31  main has moved since this branch — /catchup, re-plan, update the PR's plans
#  32  ORG_AUDIT is on and the access-and-change procedure is not written
#  33  ORG_DEPLOY_APPROVAL is required and no reviewer other than the author approved the PR
#  11  (after the merge) applied and merged, but the board could not be updated
#  other  merge.sh's own exit code: applied, and the merge did not finish

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_claude-project/skills/gitflow/scripts/issue_helpers.sh
source "$SCRIPT_DIR/issue_helpers.sh"
# shellcheck source=_claude-project/skills/gitflow/scripts/repo_kind.sh
source "$SCRIPT_DIR/repo_kind.sh"
TF_DIR=".claude/skills/terraform/scripts"
PLAN_NAME="deploy.tfplan"

for tool in gh jq terraform dot; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "deploy-org.sh: $tool is required to deploy an org repo." >&2
        exit 8
    fi
done

if ! BRANCH=$(git branch --show-current) || [ -z "$BRANCH" ]; then
    echo "deploy-org.sh: no branch checked out — run /deploy on the PR's branch." >&2
    exit 3
fi
if [ "$BRANCH" = "main" ] || [ "$BRANCH" = "master" ]; then
    echo "deploy-org.sh: on $BRANCH. In an org repo /deploy runs on the PR's branch: it applies the PR, then merges it." >&2
    exit 3
fi
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "deploy-org.sh: the working tree has uncommitted changes — /open-pr commits them; nothing was deployed." >&2
    exit 4
fi
git fetch -q origin "$BRANCH" 2>/dev/null || true
if [ "$(git rev-parse HEAD)" != "$(git rev-parse "origin/$BRANCH" 2>/dev/null || echo none)" ]; then
    echo "deploy-org.sh: $BRANCH has commits origin does not — push them (/open-pr does) so the PR is what gets applied." >&2
    exit 5
fi

if ! PR_JSON=$(gh pr list --head "$BRANCH" --state open --json number,body,baseRefName --jq '.[0] // empty') || [ -z "$PR_JSON" ]; then
    echo "deploy-org.sh: no open PR for $BRANCH — /open-pr first." >&2
    exit 9
fi
PR_NUMBER=$(jq -r '.number' <<<"$PR_JSON")
PR_BASE=$(jq -r '.baseRefName' <<<"$PR_JSON")
RELEASE_ARGS=("$@")
# A check here would still apply and merge, so there is none; and a release that
# cannot start must say so before the apply, not after the merge.
prev=""
for arg in "$@"; do
    if [ "$arg" = "--check-only" ]; then
        echo "deploy-org.sh: on a PR branch /deploy applies and merges — it has no check-only mode. Nothing was run." >&2
        exit 2
    fi
    if [ "$prev" = "--changelog-file" ] && [ ! -f "$arg" ]; then
        echo "deploy-org.sh: changelog file $arg not found. Nothing was run." >&2
        exit 2
    fi
    prev="$arg"
done
BODY_FILE=$(mktemp)
jq -r '.body' <<<"$PR_JSON" > "$BODY_FILE"

# Applying, then landing somewhere other than main, would leave main without live
# infrastructure — so both are refused before anything is planned.
if [ "$PR_BASE" != "main" ] && [ "$PR_BASE" != "master" ]; then
    echo "deploy-org.sh: PR #$PR_NUMBER targets $PR_BASE, not main — deploy $PR_BASE's PR first. Nothing was applied." >&2
    exit 30
fi
# An audited org deploys under its written procedure, and an org that requires a
# second person's approval gets it before anything is planned.
SUBS=".claude/sync-substitutions.json"
if [ "$(jq -r '.ORG_AUDIT // ""' "$SUBS" 2>/dev/null || true)" = "on" ] \
   && [ ! -f project-documentation/infrastructure-access-and-change.md ]; then
    echo "deploy-org.sh: this org repo keeps an audit trail (ORG_AUDIT=on), but project-documentation/infrastructure-access-and-change.md is not written. Nothing was applied." >&2
    exit 32
fi
if [ "$(jq -r '.ORG_DEPLOY_APPROVAL // ""' "$SUBS" 2>/dev/null || true)" = "required" ]; then
    if ! DECISION=$(gh pr view "$PR_NUMBER" --json reviewDecision --jq '.reviewDecision // ""' 2>&1); then
        echo "deploy-org.sh: could not read PR #$PR_NUMBER's review decision: $DECISION. Nothing was applied." >&2
        exit 33
    fi
    if [ "$DECISION" != "APPROVED" ]; then
        echo "deploy-org.sh: PR #$PR_NUMBER needs approval from a reviewer other than its author before it is applied (ORG_DEPLOY_APPROVAL=required; review decision: ${DECISION:-none}). Nothing was applied." >&2
        exit 33
    fi
fi

git fetch -q origin "$PR_BASE" 2>/dev/null || true
if ! git merge-base --is-ancestor "origin/$PR_BASE" HEAD; then
    echo "deploy-org.sh: $PR_BASE has moved since $BRANCH was cut. Nothing was applied." >&2
    echo "  /catchup, re-plan the changed roots, update the PR's plan blocks, then /deploy." >&2
    exit 31
fi

ROOTS_DONE=()
LIVE_ROOTS=""
cleanup() {
    rm -f "$BODY_FILE"
    while IFS= read -r r; do
        if [ -n "$r" ]; then rm -f "infra/terraform/$r/$PLAN_NAME"; fi
    done <<< "${ROOTS:-}"
}
trap cleanup EXIT

if ! ROOTS=$(bash "$TF_DIR/changed-roots.sh" "$PR_BASE"); then
    exit 2
fi
if [ -z "$ROOTS" ]; then
    if repo_holds_app; then
        echo "deploy-org.sh: PR #$PR_NUMBER changes no Terraform root — land it with /merge, and release the app with /deploy on main." >&2
    else
        echo "deploy-org.sh: PR #$PR_NUMBER changes no Terraform root. A docs change goes straight to main with /ship-main." >&2
    fi
    exit 2
fi
COUNT=$(printf '%s\n' "$ROOTS" | wc -l | tr -d ' ')
echo "gitflow: PR #$PR_NUMBER changes $COUNT root(s): $(printf '%s' "$ROOTS" | tr '\n' ' ')" >&2

echo "gitflow: waiting for CI on PR #$PR_NUMBER..." >&2
if ! "$SCRIPT_DIR/wait-for-pr-ready.sh" --pr "$PR_NUMBER"; then
    echo "deploy-org.sh: PR #$PR_NUMBER is not green — fix it on the branch. Nothing was applied." >&2
    exit 11
fi

# What else this PR changes decides whether the merge is followed by an app release.
APP_CHANGED=""
if repo_holds_app; then
    APP_CHANGED=$(git diff --name-only "origin/$PR_BASE...HEAD" \
        | grep -vE '^(infra/terraform/|project-documentation/|\.claude/)|\.md$' || true)
fi

# ─── Plan every root and compare, before applying any ──────────────────────
while IFS= read -r root; do
    if ! out=$(bash "$TF_DIR/tf.sh" "$root" init -input=false 2>&1); then
        printf '%s\n' "$out" >&2
        echo "deploy-org.sh: could not initialise $root. Nothing was applied." >&2
        exit 27
    fi
    if ! out=$(bash "$TF_DIR/tf.sh" "$root" plan -input=false -out="$PLAN_NAME" 2>&1); then
        printf '%s\n' "$out" >&2
        echo "deploy-org.sh: could not plan $root. Nothing was applied." >&2
        exit 27
    fi
    if ! fresh=$(bash "$TF_DIR/plan-summary.sh" "$root" "$PLAN_NAME"); then
        exit 27
    fi
    if ! shown=$(bash "$TF_DIR/plan-summary.sh" --from-pr "$root" < "$BODY_FILE"); then
        echo "deploy-org.sh: PR #$PR_NUMBER's body has no plan for $root. Re-plan and update the PR. Nothing was applied." >&2
        exit 26
    fi
    if [ "$fresh" = "no changes" ] && [ "$shown" != "no changes" ]; then
        echo "gitflow: $root — already live, nothing left to apply." >&2
        LIVE_ROOTS="$LIVE_ROOTS $root"
        continue
    fi
    if [ "$fresh" != "$shown" ]; then
        echo "deploy-org.sh: $root's plan now differs from the one PR #$PR_NUMBER shows. Nothing was applied." >&2
        diff <(printf '%s\n' "$shown") <(printf '%s\n' "$fresh") | sed 's/^< /  PR shows:  /; s/^> /  plan now:  /' | grep -E 'PR shows|plan now' >&2 || true
        echo "  Find what changed (a console edit, another PR), re-plan, and update the PR's plan block." >&2
        exit 26
    fi
    echo "gitflow: $root — plan matches the PR." >&2
done <<< "$ROOTS"

# ─── Apply ─────────────────────────────────────────────────────────────────
while IFS= read -r root; do
    case " $LIVE_ROOTS " in *" $root "*) ROOTS_DONE+=("$root"); continue ;; esac
    echo "gitflow: applying $root..." >&2
    if ! bash "$TF_DIR/tf.sh" "$root" apply -input=false "$PLAN_NAME" >&2; then
        echo "deploy-org.sh: applying $root failed. Nothing was merged." >&2
        if [ ${#ROOTS_DONE[@]} -gt 0 ]; then
            echo "  Already live: ${ROOTS_DONE[*]}. Fix forward on this branch and /deploy again." >&2
        else
            echo "  No root finished applying; $root may be partly applied. Fix forward on this branch and /deploy again." >&2
        fi
        exit 28
    fi
    ROOTS_DONE+=("$root")
done <<< "$ROOTS"

# ─── Land it ───────────────────────────────────────────────────────────────
echo "gitflow: applied ${ROOTS_DONE[*]} — merging PR #$PR_NUMBER." >&2
set +e
GITFLOW_ORG_DEPLOY=1 "$SCRIPT_DIR/merge.sh" --pr "$PR_NUMBER" --base "$PR_BASE"
MERGE_RC=$?
set -e
if [ "$MERGE_RC" -ne 0 ]; then
    echo "deploy-org.sh: applied ${ROOTS_DONE[*]}, but the merge did not finish (merge.sh exit $MERGE_RC)." >&2
    echo "  Fix the cause above and run /deploy again: the applied roots plan to nothing, so it only merges." >&2
    exit "$MERGE_RC"
fi

# ─── The reference follows the live state, straight onto main ──────────────
# merge.sh left this checkout on main at the merged tip.
REF_FAILED=0
if ! bash "$TF_DIR/gen-reference.sh" >&2; then
    REF_FAILED=1
elif [ -n "$(git status --porcelain -- project-documentation)" ]; then
    git add -- project-documentation
    if ! git commit -q --no-verify -m "📚 docs: regenerate the infrastructure reference" || ! git push -q origin main; then
        REF_FAILED=1
    else
        echo "gitflow: regenerated reference pushed to main." >&2
    fi
fi
if [ "$REF_FAILED" -ne 0 ]; then
    echo "deploy-org.sh: applied and merged, but the infrastructure reference did not reach main — see above." >&2
    echo "  Fix the cause, then run .claude/skills/terraform/scripts/gen-reference.sh and /ship-main." >&2
fi

# ─── The app half: a combo PR that changes the app is released from main ────
if [ -n "$APP_CHANGED" ]; then
    if [ "$REF_FAILED" -ne 0 ]; then
        echo "  PR #$PR_NUMBER also changes the app — release it with /deploy on main once the reference is on main." >&2
        exit 29
    fi
    if [ ${#RELEASE_ARGS[@]} -eq 0 ]; then
        echo "gitflow: applied and merged. PR #$PR_NUMBER also changes the app — release it with /deploy on main." >&2
        exit 0
    fi
    echo "gitflow: applied and merged. PR #$PR_NUMBER also changes the app — releasing it from main." >&2
    exec "$SCRIPT_DIR/deploy.sh" "${RELEASE_ARGS[@]}"
fi

# ─── What shipped moves on the board ───────────────────────────────────────
# The same closing keywords deploy.sh reads, from the body merge.sh just landed.
SHIPPED=$(grep -ohiE '(close[sd]?|fix(es|ed)?|resolve[sd]?)[[:space:]]+#[0-9]+([[:space:]]*,[[:space:]]*#[0-9]+)*' "$BODY_FILE" \
    | grep -oE '[0-9]+' | sort -u || true)
BOARD_FAILED=0
for num in $SHIPPED; do
    move_issue_to_deployed "$num" || BOARD_FAILED=1
done
if [ "$BOARD_FAILED" -ne 0 ]; then
    echo "deploy-org.sh: applied and merged, but the board could not be updated for every shipped issue — see above." >&2
    exit 11
fi
[ "$REF_FAILED" -eq 0 ] || exit 29

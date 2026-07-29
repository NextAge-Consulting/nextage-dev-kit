# New Project Setup

The single walkthrough for taking a brand-new project from nothing to "kit installed, pipeline wired, ready to develop." Hand this whole doc to Claude and say *"walk me through new project setup"* — Claude works the at-a-glance checklist top to bottom, doing every `[claude]` step itself and pausing for every `[you]` step.

**Legend:**

- `[claude]` — Claude does it (runs the command, edits the file).
- `[you]` — human-only: interactive auth, a web-console click, a billing/IAM action, or obtaining a secret. Claude stops and tells you exactly what to do.
- `[claude+you]` — Claude drives, but needs a value or confirmation from you first.

**Verification is continuous:** each section ends with the command that proves it worked. Run it and read the output — don't assume a step took.

---

## At-a-glance checklist

### One-time per machine (skip anything already done)

- [ ] **P0** — Machine prerequisites installed: `git`, `gh` (authenticated, `repo`+`project` scopes), `jq`, `node`/`npm` (or `python3`), `shasum`, plus optional `shellcheck` / `agent-browser` `[you]`
- [ ] **P1** — Kit installed globally: `/install-kit` `[claude]`
- [ ] **P2** — (optional) Custom statusline: `/install-statusline` `[claude]`
- [ ] **P3** — (optional) Claude Project Launcher: `/install-cpl` `[claude]`

### Per new project

- [ ] **1** — Project exists as a local git repo `[claude+you]`
- [ ] **2** — GitHub repo created and `main` pushed `[claude+you]`
- [ ] **3** — Confirm `main` requires no PR `[claude]`
- [ ] **4** — `/sync-starter-kit` run; substitutions walkthrough completed `[claude+you]`
- [ ] **5** — Gemini Code Review installed + repo linked — or explicitly marked not-installed `[you]` then `[claude]`
- [ ] **6** — Secrets & env: `.env`, GitHub Actions secrets, MCP API keys `[claude+you]`
- [ ] **7** — Project-specific deploy workflow authored, + registry repo AND lifecycle policy per image (if this project deploys) `[claude+you]`
- [ ] **8** — Every section's verify command passes `[claude]`
- [ ] **9** — First `/work` session — pipeline proven end-to-end `[claude]`

---

## Detailed steps

### P0 — Machine prerequisites `[you]`

These are machine-level, one-time. Install whatever is missing:

| Need | Install (macOS) | Why |
|---|---|---|
| `git` | preinstalled / `brew install git` | everything |
| `gh` (GitHub CLI) | `brew install gh` | repo, PR, project-board ops |
| `gh` authenticated | `gh auth login` | — |
| `gh` `repo` + `project` scopes | `gh auth refresh -s repo,project` | PR/issue metadata + project board |
| `jq` | `brew install jq` | every sync + gitflow script |
| `node` + `npm` | `brew install node` (or nvm/volta) | Node projects; `/deploy` version bump |
| `python3` | `brew install python3` | only if project has `pyproject.toml` |
| `shasum` / `sha256sum` | preinstalled | sync baseline SHAs |
| `shellcheck` | `brew install shellcheck` | WARN — required before committing script edits |
| `agent-browser` | see github.com/vercel-labs/agent-browser | WARN — only for `/e2e` flows |

**Verify:**

```bash
bash --version | head -1                 # >= 3.2 (macOS default is fine)
git --version && gh --version | head -1
gh auth status                           # authenticated
gh auth token | xargs -I{} gh api -H "Authorization: token {}" -i user 2>/dev/null \
  | grep -i '^x-oauth-scopes:'           # must list BOTH repo and project
gh api graphql -f query='{viewer{login}}'  # GraphQL roundtrip works
jq --version
command -v shasum sha256sum | head -1    # sync engine SHA computation
command -v sed awk curl >/dev/null && echo "sed/awk/curl ok"
node -v && npm -v                        # if the project has package.json
python3 --version                        # only if the project has pyproject.toml
```

Optional, and only needed for specific workflows — skip without consequence otherwise:

```bash
shellcheck --version | awk '/^version:/{print $2}'   # before committing script edits
agent-browser --version                              # only for /e2e flows
```

Both `repo` and `project` scopes are required. If either is missing: `gh auth refresh -s repo,project`.

### P1 — Install the kit globally `[claude]`

From inside the **starter-kit repo**, run `/install-kit`. This copies `_claude-global/` into `~/.claude/` — the global `/work` bootstrap — and writes `~/.claude/starter-kit-config.json` with `kit_path`. Idempotent.

> `/work` is global because it must be invokable from the agents view *before* the session is inside any repo. Everything else a project needs is per-project, delivered by sync.

**The kit maintainer runs `/install-kit --maintainer` instead.** That adds the maintainer surface — `sync-starter-kit.sh`, the `/sync-starter-kit` command, and `kit-maintainer.md`. Only the person who syncs projects into the kit needs it; every other dev gets the consumer install above and receives kit updates when the maintainer syncs their project. See `HANDBOOK.md` §0.

**Verify (every dev):**

```bash
ls ~/.claude/commands/work.md                       # /work available
jq -r .kit_path ~/.claude/starter-kit-config.json   # points at your kit clone
```

**Verify (maintainer only):**

```bash
test -x ~/.claude/scripts/sync-starter-kit.sh && echo "sync script installed + executable"
ls ~/.claude/commands/sync-starter-kit.md ~/.claude/kit-maintainer.md
grep -q '@kit-maintainer.md' ~/.claude/CLAUDE.md && echo "maintainer rule imported"
ls ~/.claude/kitmaster                              # marker: makes block-kit-edit.sh inert
```

### P2 — Custom statusline (optional) `[claude]`

`/install-statusline` copies `_statusline/statusline.sh` to `~/.claude/statusline.sh` and makes it executable. Enable it in `~/.claude/settings.json`:

```json
{ "statusLine": { "type": "command", "command": "~/.claude/statusline.sh", "padding": 0 } }
```

**Verify:** `test -x ~/.claude/statusline.sh && echo ok`

### P3 — Claude Project Launcher (optional) `[claude]`

`/install-cpl` installs/updates CPL. Only if you use the launcher.

---

### 1 — Project exists as a local git repo `[claude+you]`

Either clone an existing repo, or in a fresh directory:

```bash
git init
# ... scaffold the project (framework init, package.json, etc.) ...
git add -A && git commit -m "initial commit"
```

The project does NOT need any `.claude/` content yet — that arrives in step 4.

### 2 — Create the GitHub repo and push `main` `[claude+you]`

Claude can create it via `gh`:

```bash
gh repo create <owner>/<repo> --private --source=. --remote=origin --push
```

Confirm the `<owner>/<repo>` slug with you first (it becomes the `OWNER_REPO` substitution in step 4).

**Verify:** `gh repo view <owner>/<repo>` resolves; `main` exists on origin.

### 3 — Confirm `main` requires no PR `[claude]`

**No branch protection.** The pipeline does not use it. `/merge` self-gates by reading the PR's CI check-runs directly — independent of GitHub's "required checks" config — so the gate works on any repo with nothing configured. There is nothing to set up here.

The one hard requirement: **`main` must not require a PR.** A fresh repo has require-PR off by default, so this is already true — just don't turn it on. The direct-push paths (`/ship-main`, `/deploy`'s bump push, the changes `/sync-starter-kit` leaves you to land) push straight to `main`, and GitHub rejects those if require-PR is on. `enforce_admins` is irrelevant — nothing admin-merges.

**Verify:** `main` does not require a PR (the default on a new repo). If a protection rule was ever added, confirm require-PR is off.

### 4 — Run `/sync-starter-kit` `[claude+you]`

From the **project root** (not a worktree, not inside the kit), run `/sync-starter-kit`. First-run flow:

1. **Scan** — compares kit templates against the (empty) project; bootstraps `.claude/sync-substitutions.json`.
2. **Substitutions walkthrough (Step 1.5)** — Claude walks you through each empty placeholder, one at a time. The ones you'll almost always set:
   - `OWNER_REPO` — `<owner>/<repo>` from step 2.
   - `ORG` — GitHub org login.
   - `PROJECT_ABBREV` — short label for `wip/<abbrev>-…` branch names (Claude pre-computes a default from the dir name; accept or shorten).
   - `GEMINI_NOT_INSTALLED` — leave empty for now if you're installing Gemini in step 5; set to `"true"` if this repo will not have Gemini.
   - `GITFLOW_PROJECT_ID` + the `GITFLOW_STATUS_*` IDs — only if you use a GitHub Project board (Claude can run the `gh api graphql` discovery for you). Leave empty / `_intentionally_empty` to skip board integration.
   - `DEPLOY_WORKFLOWS` — space-separated deploy workflow filenames; leave empty to default to `deploy.yml`.

   > Three states per key (HANDBOOK §9.7): **missing** = undecided, marker survives, re-nags every sync; **empty string** = intentionally disabled; **populated** = normal value. `_intentionally_empty` distinguishes "informed disable" from "deferred."
3. **postCreate auto-suggest (Step 1.6)** — Claude detects your package manager and offers a `worktree.postCreate` command (e.g. `npm install`) so each `/work` worktree gets real `node_modules`.
4. **Per-file review (Steps 2–5)** — accept the kit files (`.claude/`, `.github/workflows/`, `.gemini/`, `.mcp.json`, `.commitlintrc.json`, `biome.json`, `.semgrepignore`) and the `.gitignore` additions.
5. **Finalize (Step 6)** — stamps the lockfile. Sync does **not** commit or push; the synced files are left uncommitted in the working tree. Land them with `/ship-main` (commits + pushes straight to `main`).

**Verify:**

```bash
jq -e . .claude/sync-substitutions.json >/dev/null && echo "substitutions valid JSON"
jq -e . .claude/settings.json >/dev/null && echo "settings valid JSON"
ls .claude/gitflow-project.conf
for h in .claude/hooks/*.sh; do [ -x "$h" ] || echo "NOT EXECUTABLE: $h"; done; echo "hooks checked"
```

### 5 — Gemini Code Review `[you]` → `[claude]`

Full procedure (two lanes — billing/IAM owner vs configurer) lives in **`gemini-code-review-setup.md`**. Summary:

- `[you]` (or org owner): create/select the GCP project with billing, grant IAM, install the **Gemini Code Assist** GitHub App for the org, and **link this repo** to the connection.
- Smoke test: open a throwaway PR, comment `/gemini review`, expect `gemini-code-assist[bot]` to post a review within ~5 min.
- `[claude]`: once confirmed installed, ensure `GEMINI_NOT_INSTALLED` is empty in `.claude/sync-substitutions.json` (Gemini gating ON for `/open-pr`, `/triage`, `/merge`). If you are NOT installing Gemini, set it to `"true"` so gitflow doesn't wait on a review that never comes.

> Gemini is **advisory** — it surfaces review comments; it does not block merges by itself. `GEMINI_NOT_INSTALLED` only controls whether gitflow *waits* for a review before proceeding.

### 6 — Secrets & env `[claude+you]`

- **`.env`** (root, gitignored) — dev environment. Claude reads existing values first, only adds new ones; never overwrites secrets without consent.
- **MCP keys** — `.mcp.json` declares servers (Ref, Exa). Export their keys in your shell profile or `.env`:
  ```bash
  export REF_API_KEY="…"
  export EXA_API_KEY="…"
  ```
- **GitHub Actions secrets** `[you]` — set under repo (or org) *Settings → Secrets and variables → Actions*. Only what your workflows reference (e.g. release-bot App credentials at org level, Neon/DB secrets for CI test branches, deploy credentials).

**Verify:** every `${VAR}` referenced in `.mcp.json` is exported in your shell:

```bash
grep -oE '\$\{[A-Z_]+\}' .mcp.json 2>/dev/null | tr -d '${}' | sort -u \
  | while read -r v; do [ -n "${!v:-}" ] && echo "  set:   $v" || echo "  UNSET: $v"; done
```

### 7 — Deploy workflow (if this project deploys) `[claude+you]`

Deploy workflows are **project-specific** — the kit does NOT ship one (different targets, registries, hosts). Author `.github/workflows/<name>.yml` with a `workflow_dispatch:` trigger and **no** `push:` trigger (so `/deploy` is the only thing that fires it). List the filename(s) in the `DEPLOY_WORKFLOWS` substitution. See HANDBOOK §11.9 for the per-app `detect` pattern when a monorepo splits deploys.

**Verify:** each workflow named in `DEPLOY_WORKFLOWS` exists:

```bash
jq -r '.DEPLOY_WORKFLOWS // ""' .claude/sync-substitutions.json \
  | tr ' ' '\n' | grep -v '^$' \
  | while read -r w; do ls ".github/workflows/$w" >/dev/null 2>&1 && echo "  ok:      $w" || echo "  MISSING: $w"; done
```

Empty `DEPLOY_WORKFLOWS` means this repo doesn't deploy — record that in `_intentionally_empty` so the sync walkthrough stops asking.

#### 7a — Container registry: create the repository AND its lifecycle policy `[claude]`

For a container deploy, **every** image repository needs two things at creation,
not one. Creating the repository is self-enforcing — the first push fails without
it. The lifecycle policy is not: nothing ever fails, storage just grows forever,
and the bill shows up months later.

Do both in the same step, for each image repository:

```bash
# read the target from the project's own substitutions — never hardcode
PROFILE=$(jq -r .AWS_PROFILE .claude/sync-substitutions.json)
REGION=$(jq -r .AWS_REGION  .claude/sync-substitutions.json)

aws ecr create-repository --repository-name "<repo>" \
  --image-tag-mutability MUTABLE \
  --image-scanning-configuration scanOnPush=true \
  --encryption-configuration encryptionType=AES256 \
  --profile "$PROFILE" --region "$REGION"

aws ecr put-lifecycle-policy --repository-name "<repo>" \
  --lifecycle-policy-text '{"rules":[{"rulePriority":1,
    "description":"Expires images after 3 images created.",
    "selection":{"tagStatus":"any","countType":"imageCountMoreThan","countNumber":3},
    "action":{"type":"expire"}}]}' \
  --profile "$PROFILE" --region "$REGION"
```

**Why 3.** One deploy pushes several tags (`latest`, short-sha, `v<timestamp>`)
that count as a single image, plus a `buildcache` image. Three keeps roughly the
last two deploys — one more than has ever actually been rolled back to. Rollback
is a last resort, not a workflow; don't pay storage rent to make it marginally
easier.

**Name the repository to match the CI push policy.** That policy is normally
scoped by prefix (e.g. `repository/<project>-*`). A repository named for the
project alone (`myproj`) does **not** match `myproj-*`, and the push fails with
an opaque 403 — name it `myproj-<service>`.

**Verify** — both must exist for every repository:

```bash
PROFILE=$(jq -r .AWS_PROFILE .claude/sync-substitutions.json)
REGION=$(jq -r .AWS_REGION  .claude/sync-substitutions.json)
for r in $(aws ecr describe-repositories --profile "$PROFILE" --region "$REGION" \
             --query 'repositories[].repositoryName' --output text); do
  aws ecr get-lifecycle-policy --repository-name "$r" --profile "$PROFILE" --region "$REGION" \
    >/dev/null 2>&1 && echo "  ok:            $r" || echo "  NO LIFECYCLE:  $r"
done
```

**Grant the CI identity `ecr:GetLifecyclePolicy`.** The push permissions every
container project already has (`PutImage`, `UploadLayerPart`, `DescribeRepositories`,
…) do **not** include it, so the workflow check below cannot read the policy it is
checking. Add it to the same statement that scopes the push, alongside
`ecr:DescribeRepositories`:

```
"ecr:DescribeRepositories",
"ecr:GetLifecyclePolicy"
```

Read-only, and the guard is useless without it. `ecr:PutLifecyclePolicy` is
deliberately **not** granted — CI verifies the policy, a human creates it.

**Put the check in the deploy workflow, not only in this document.** That is the
part that actually prevents recurrence, and it generalises well beyond ECR.

Adding a container to an *existing* project never involves reading this file —
you copy the neighbouring `Dockerfile`, `docker-compose` service and deploy
workflow, because that is where the working pattern lives. A setup step that
exists only in a setup doc therefore gets skipped every time after the first.
Make the deploy workflow assert it instead:

```yaml
- name: Verify ECR repository and lifecycle policy
  run: |
    REPO="${{ env.IMAGE_NAME }}"; REGION="${{ secrets.AWS_REGION }}"
    aws ecr describe-repositories --repository-names "$REPO" --region "$REGION" >/dev/null 2>&1 || {
      echo "::error::ECR repository '$REPO' does not exist. Fix: aws ecr create-repository …"; exit 1; }
    if ! ERR=$(aws ecr get-lifecycle-policy --repository-name "$REPO" --region "$REGION" 2>&1); then
      case "$ERR" in
        *AccessDenied*|*not\ authorized*)
          echo "::error::CI identity lacks ecr:GetLifecyclePolicy on '$REPO' — cannot verify. Grant it; do not weaken this check."; exit 1 ;;
        *)
          echo "::error::'$REPO' has NO lifecycle policy — images accumulate forever. Fix: aws ecr put-lifecycle-policy …"; exit 1 ;;
      esac
    fi
```

The requirement then travels with the thing that gets copied, and a new service
cannot deploy without satisfying it.

**A guard must never guess why it failed.** The first version of this check sent
both failures to `/dev/null` and reported "NO lifecycle policy" for either one —
so a missing *permission* was announced as a missing *policy*, sending the reader
to fix something that was already correct. Branching on the error is four extra
lines and the difference between a guard that diagnoses and one that misleads.

**The general rule this is an instance of:** when omitting a setup step produces
*no failure* — only slow cost, drift, or silent risk — a checklist entry is not
enough, because the checklist is read once and the pattern is copied forever.
Encode it as an assertion in the pipeline.

**Also run the verify against established projects.** A missing policy never
fails a build, so nothing surfaces it retroactively. First audit across two
accounts: six of eight repositories had no policy — 648 dead images, 138 GB.

### 8 — Full verification `[claude]`

Re-run each section's **Verify** block above, top to bottom, and read the output. Resolve anything that reports missing or unset before developing. The machine checks (P0) only need re-running if you changed toolchain since; the project checks (steps 4, 6, 7, 7a) are the ones that catch a half-finished setup. Step 7a's verify is also worth running periodically against **established** projects — a missing lifecycle policy never fails a build, so nothing else will surface it.

### 9 — First work session `[claude]`

```bash
/work <issue#>     # or bare /work to start a feature branch with no issue
```

`/work` fast-forwards local `main`, creates/enters the `current/` worktree on a fresh feature branch, links the issue (board → In Progress if configured), runs your `postCreate`, and reads the issue so Claude can propose an approach. From here the normal loop is live: `/commit` → `/open-pr` → `/triage` → `/merge` → `/deploy`. See `GITFLOW-CHEATSHEET.md`.

---

## What "ready to develop" means

When all nine boxes are checked and every verify block passes: the project has the full `.claude/` ruleset + gitflow subsystem, CI on every PR (commitlint, type-check, Biome, Semgrep, Vitest), Gemini review (if installed), and a proven `/work → /merge → /deploy` pipeline. Start building.

## Related docs

- `GITFLOW-CHEATSHEET.md` — the day-to-day command flow once setup is done
- `gemini-code-review-setup.md` — full Gemini Code Assist install (step 5)
- `KIT-REPO-GITHUB-CONFIG.md` — repo / GitHub config reference
- `HANDBOOK.md` — §0 kit layout, §9 sync workflow, §9.7 substitutions, §11 workflow templates, §6.5 deploy direct-push, §9.4.1 sync does no git

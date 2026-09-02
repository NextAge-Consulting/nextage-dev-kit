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

- [ ] **0** — AWS account access: client creates a cross-account role `[client]` → profile added `[you]` (only if this project uses AWS)
- [ ] **1** — Project exists as a local git repo `[claude+you]`
- [ ] **2** — GitHub repo created and `main` pushed `[claude+you]`
- [ ] **3** — Confirm `main` requires no PR `[claude]`
- [ ] **4** — `/sync-dev-kit` run; substitutions walkthrough completed `[claude+you]`
- [ ] **5** — Gemini Code Review installed + repo linked — or explicitly marked not-installed `[you]` then `[claude]`
- [ ] **6** — Secrets & env: `.env`, GitHub Actions secrets, MCP API keys `[claude+you]`
- [ ] **7** — Project-specific CodeBuild deploy pipeline authored (buildspecs + projects + CodeConnections), + registry repo AND lifecycle policy per image (if this project deploys) `[claude+you]`
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

From inside the **dev-kit repo**, run `/install-kit`. This copies `_claude-global/` into `~/.claude/` — the global `/work` bootstrap — and writes `~/.claude/dev-kit-config.json` with `devKitPath`. Idempotent.

> `/work` is global because it must be invokable from the agents view *before* the session is inside any repo. Everything else a project needs is per-project, delivered by sync.

**The kit maintainer runs `/install-kit --maintainer` instead.** That adds the maintainer surface — `sync-dev-kit.sh`, the `/sync-dev-kit` command, and `kit-maintainer.md`. Only the person who syncs projects into the kit needs it; every other dev gets the consumer install above and receives kit updates when the maintainer syncs their project. See `handbook.md` §0.

**Verify (every dev):**

```bash
ls ~/.claude/commands/work.md                       # /work available
jq -r .devKitPath ~/.claude/dev-kit-config.json  # points at your kit clone
```

**Verify (maintainer only):**

```bash
test -x ~/.claude/scripts/sync-dev-kit.sh && echo "sync script installed + executable"
ls ~/.claude/commands/sync-dev-kit.md ~/.claude/kit-maintainer.md
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

### 0 — AWS account access `[client]` → `[you]`

Skip if the project touches no AWS.

**Ask the client for a cross-account ROLE, never an IAM user.** A user means a
standing identity and a password living in their account for as long as the
engagement lasts, and a second thing to remember to remove. A role holds no
credentials at all — it is assumed on demand from the NextAge account, expires by
itself, and is revoked by deleting one object.

It also collapses the sign-in problem. Every client role is assumed from the same
NextAge account, so **one `aws login` reaches every client**. With per-account IAM
users, each account needs its own browser sign-in, and those collide: `aws login`
reuses whatever console session the browser already holds, so authenticating to a
second account while signed into a first returns a bare `400` and hangs (see
`cli-utilities.md`).

**Send the client this**, with the account id filled in — the account id is
`aws sts get-caller-identity --profile nextage --query Account --output text`. It is written
to be forwarded as-is:

```
Please create an IAM role in your AWS account so we can build and manage your
infrastructure without a password or access key of ours living in your account.

In the AWS console: IAM → Roles → Create role

  Trusted entity type:  AWS account
  Account:              Another AWS account
  Account ID:           <NEXTAGE ACCOUNT ID>
  Permissions:          AdministratorAccess
  Role name:            NextAgeOperator

That is all we need. A role has no password and no access keys — it can only be
used by our AWS account, and it issues short-lived credentials each time.

Two things worth knowing:

  - AdministratorAccess is what the initial build-out needs, because it creates
    networking, compute, storage, database and IAM resources. Once the build is
    done you can narrow the permissions or detach them entirely, and nothing
    about how we connect has to change.

  - To revoke our access at any time, delete the role. It takes effect
    immediately and leaves nothing behind.
```

**Then, on your machine**, add the profile — no second login, no keys:

```bash
cat >> ~/.aws/config <<'EOF'

[profile <project>]
role_arn = arn:aws:iam::<CLIENT_ACCOUNT_ID>:role/NextAgeOperator
source_profile = nextage
region = <their-region>
EOF
```

Record the account id, region and profile name in the project's
`.claude/sync-substitutions.json` as `AWS_ACCOUNT_ID`, `AWS_REGION`, `AWS_PROFILE`.

**Console access** is the account menu → Switch role, with their account id and
`NextAgeOperator`. Set a display colour; with several clients it is the only thing
that tells you which account a window is about to change. The console's region is a
browser-wide preference and does **not** follow the role, so it stays wherever you
last set it.

**Verify** — the ARN comes back as an assumed role, and a real call succeeds:

```bash
aws sts get-caller-identity --profile <project> --query Arn --output text
aws ec2 describe-vpcs --profile <project> --query 'length(Vpcs)' --output text
```

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

Confirm the `<owner>/<repo>` slug with you first.

**Verify:** `gh repo view <owner>/<repo>` resolves; `main` exists on origin.

### 3 — Confirm `main` requires no PR `[claude]`

**No branch protection.** The pipeline does not use it. `/merge` self-gates by reading the PR's CI check-runs directly — independent of GitHub's "required checks" config — so the gate works on any repo with nothing configured. There is nothing to set up here.

The one hard requirement: **`main` must not require a PR.** A fresh repo has require-PR off by default, so this is already true — just don't turn it on. The direct-push paths (`/ship-main`, `/deploy`'s bump push, the changes `/sync-dev-kit` leaves you to land) push straight to `main`, and GitHub rejects those if require-PR is on. `enforce_admins` is irrelevant — nothing admin-merges.

**Verify:** `main` does not require a PR (the default on a new repo). If a protection rule was ever added, confirm require-PR is off.

### 4 — Run `/sync-dev-kit` `[claude+you]`

From the **project root** (not inside the kit), run `/sync-dev-kit`. First-run flow:

1. **Scan** — compares kit templates against the (empty) project; bootstraps `.claude/sync-substitutions.json`.
2. **Substitutions walkthrough (Step 1.5)** — Claude walks you through each empty placeholder, one at a time. The ones you'll almost always set:
   - `ORG` — GitHub org login.
   - `PROJECT_ABBREV` — short label for `wip/<abbrev>-…` branch names (Claude pre-computes a default from the dir name; accept or shorten).
   - `GEMINI_NOT_INSTALLED` — leave empty for now if you're installing Gemini in step 5; set to `"true"` if this repo will not have Gemini.
   - `GITFLOW_PROJECT_ID` + the `GITFLOW_STATUS_*` IDs — only if you use a GitHub Project board (Claude can run the `gh api graphql` discovery for you). Leave empty / `_intentionally_empty` to skip board integration.
   - `DEPLOY_BACKEND` + `DEPLOY_WORKFLOWS` + `CODEBUILD_PROJECT_PREFIX` — the deploy pipeline; see step 7. Leave all empty if this repo doesn't deploy.

   > Three states per key (handbook §9.7): **missing** = undecided, marker survives, re-nags every sync; **empty string** = intentionally disabled; **populated** = normal value. `_intentionally_empty` distinguishes "informed disable" from "deferred."
3. **Per-file review (Steps 2–5)** — accept the kit files (`.claude/`, `.github/workflows/`, `.gemini/`, `.mcp.json`, `.commitlintrc.json`, `biome.json`, `.semgrepignore`) and the `.gitignore` additions.
4. **Finalize (Step 6)** — stamps the lockfile. Sync does **not** commit or push; the synced files are left uncommitted in the working tree. Land them with `/ship-main` (commits + pushes straight to `main`).

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
- **MCP keys** `[optional]` — `.mcp.json` declares the Exa server. Nothing breaks without it; the `research` skill's tiers 0–2 use built-in tools. To enable tier 3, export the key in your shell profile or `.env`:
  ```bash
  export EXA_API_KEY="…"
  ```
- **GitHub Actions secrets** `[you]` — set under repo (or org) *Settings → Secrets and variables → Actions*. Only what CI references (e.g. Neon/DB secrets for CI test branches). **No AWS credential belongs here** — deploys run on CodeBuild under a service role (step 7).

**Verify:** every `${VAR}` referenced in `.mcp.json` is exported in your shell:

```bash
grep -oE '\$\{[A-Z_]+\}' .mcp.json 2>/dev/null | tr -d '${}' | sort -u \
  | while read -r v; do [ -n "${!v:-}" ] && echo "  set:   $v" || echo "  UNSET: $v"; done
```

### 7 — Deploy pipeline (if this project deploys) `[claude+you]`

**Deploys run on AWS CodeBuild.** Everything that touches AWS runs in AWS; only PR CI and
commit linting stay on GitHub Actions (`infrastructure.md`). **Start a new project here** —
standing the deploy up on Actions intending to move it later is the expensive path.

The pipeline is **project-specific** — the kit ships no buildspec (different targets,
registries, hosts). Per deployable service, author a buildspec in the repo and provision a
CodeBuild project named `<CODEBUILD_PROJECT_PREFIX><service>`, plus one for the migration if
the project has a database. All of them share the one `<project>-codebuild-deploy` service
role (`infrastructure.md`). See handbook §11.9 for the per-app `detect` pattern when a
monorepo splits deploys.

Set in `.claude/sync-substitutions.json`:

- `DEPLOY_BACKEND` — `codebuild`. It is the default, so leaving it unset works; set it explicitly anyway, so the file records the decision.
- `DEPLOY_WORKFLOWS` — the service list, one `deploy-<service>.yml`-shaped name per service. It stays the single service list under both backends: `deploy.sh` maps each name to its CodeBuild project by stripping `deploy-` / `.yml` and applying the prefix, so there is no second list to drift.
- `CODEBUILD_PROJECT_PREFIX` — e.g. `myproj-deploy-`. Required; `/deploy` exits 2 without it.
- `CODEBUILD_MIGRATE_PROJECT` — only when the migration project does not follow the prefix pattern.
- `MIGRATE_WORKFLOW` — if this project migrates a database. `/deploy` runs it first and gates on it.
- `AWS_ACCOUNT_ID`, `AWS_REGION`, `AWS_PROFILE`.

Empty `DEPLOY_WORKFLOWS` means this repo doesn't deploy — record that in
`_intentionally_empty` so the sync walkthrough stops asking. Empty with `MIGRATE_WORKFLOW`
set means a migration-only deploy.

**Verify:** every project `/deploy` will dispatch exists in the account:

```bash
PROFILE=$(jq -r .AWS_PROFILE .claude/sync-substitutions.json)
REGION=$(jq -r .AWS_REGION  .claude/sync-substitutions.json)
PREFIX=$(jq -r .CODEBUILD_PROJECT_PREFIX .claude/sync-substitutions.json)
jq -r '[.DEPLOY_WORKFLOWS, .MIGRATE_WORKFLOW] | map(select(. != null and . != "")) | join(" ")' \
     .claude/sync-substitutions.json \
  | tr ' ' '\n' | grep -v '^$' \
  | while read -r w; do
      p="${PREFIX}$(echo "${w#deploy-}" | sed 's/\.yml$//')"
      aws codebuild batch-get-projects --names "$p" --profile "$PROFILE" --region "$REGION" \
        --query 'projects[0].name' --output text 2>/dev/null | grep -q . \
        && echo "  ok:      $p" || echo "  MISSING: $p"
    done
```

#### 7-prereq — CodeConnections, once per AWS account `[claude+you]`

CodeBuild clones over a GitHub App connection, and it must be both **completed** and
**registered as the account's source credential** — two separate things, and skipping the
second fails every build at `DOWNLOAD_SOURCE` with "authentication required" while the
connection itself reads `AVAILABLE`.

```bash
PROFILE=$(jq -r .AWS_PROFILE .claude/sync-substitutions.json)
REGION=$(jq -r .AWS_REGION  .claude/sync-substitutions.json)

# 1. Create it. The CLI leaves it PENDING; a human finishes the handshake in the console.
aws codeconnections create-connection --provider-type GitHub --connection-name "<project>-github" \
  --profile "$PROFILE" --region "$REGION"

# 2. [you] Console → Developer Tools → Connections → Update pending connection.

# 3. Register it account-wide.
aws codebuild import-source-credentials --server-type GITHUB --auth-type CODECONNECTIONS \
  --token "<connection-arn>" --profile "$PROFILE" --region "$REGION"
```

**Verify:** `aws codeconnections list-connections` reports `AVAILABLE`, and
`aws codebuild list-source-credentials` lists the ARN.

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
    "description":"Expire untagged after 1 day.",
    "selection":{"tagStatus":"untagged","countType":"sinceImagePushed","countUnit":"days","countNumber":1},
    "action":{"type":"expire"}},{"rulePriority":2,
    "description":"Expires images after 3 images created.",
    "selection":{"tagStatus":"any","countType":"imageCountMoreThan","countNumber":3},
    "action":{"type":"expire"}}]}' \
  --profile "$PROFILE" --region "$REGION"
```

**This exact two-rule text is what the buildspec guard below prints as its
remediation.** Keep the two identical. A guard that tells you to paste a policy
different from the one the setup step creates teaches the reader that one of them
is wrong, and they cannot tell which.

**Why 3.** One deploy pushes several tags (`latest`, short-sha, `v<timestamp>`)
that count as a single image, plus a `buildcache` image that takes one of the three
slots — so the real rollback depth is the current release plus one prior. Rollback
is a last resort rather than a workflow, and any older release is rebuildable from
its git sha; don't pay storage rent to make it marginally easier.

**Why the untagged rule as well.** Each build replaces the `buildcache` tag, which
orphans the previous cache image. That churn, not released images, is the bulk of
what accumulates in a repository with no policy. Rule 1 claims untagged images
before rule 2 can, so they expire on age rather than waiting to fall out of a count. Untagged layers still referenced by the live `buildcache`
manifest list are never expired regardless: ECR will not break a manifest list, so
a healthy repository still shows untagged images and that is not a policy failure.

**Name the repository to match the push policy on the CodeBuild service role.** That policy is normally
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

**Grant the CodeBuild service role `ecr:GetLifecyclePolicy`.** The push permissions every
container project already has (`PutImage`, `UploadLayerPart`, `DescribeRepositories`,
…) do **not** include it, so the buildspec check below cannot read the policy it is
checking. Add it to the same statement that scopes the push, alongside
`ecr:DescribeRepositories`:

```
"ecr:DescribeRepositories",
"ecr:GetLifecyclePolicy"
```

Read-only, and the guard is useless without it. `ecr:PutLifecyclePolicy` is
deliberately **not** granted — the build verifies the policy, a human creates it.

**Put the check in the buildspec, not only in this document.** That is the
part that actually prevents recurrence, and it generalises well beyond ECR.

Adding a container to an *existing* project never involves reading this file —
you copy the neighbouring `Dockerfile`, `docker-compose` service and buildspec,
because that is where the working pattern lives. A setup step that
exists only in a setup doc therefore gets skipped every time after the first.
Make the buildspec assert it instead, in `pre_build`:

```yaml
pre_build:
  commands:
    - |
      aws ecr describe-repositories --repository-names "$IMAGE_NAME" --region "$AWS_REGION" >/dev/null 2>&1 || {
        echo "ERROR: ECR repository '$IMAGE_NAME' does not exist. Fix: aws ecr create-repository …"; exit 1; }
    - |
      if ! ERR=$(aws ecr get-lifecycle-policy --repository-name "$IMAGE_NAME" --region "$AWS_REGION" 2>&1); then
        case "$ERR" in
          *AccessDenied*|*not\ authorized*)
            echo "ERROR: the CodeBuild service role lacks ecr:GetLifecyclePolicy on '$IMAGE_NAME' — cannot verify. Grant it; do not weaken this check."; exit 1 ;;
          *)
            echo "ERROR: '$IMAGE_NAME' has NO lifecycle policy — images accumulate forever. Fix: aws ecr put-lifecycle-policy …"; exit 1 ;;
        esac
      fi
```

The requirement then travels with the thing that gets copied, and a new service
cannot deploy without satisfying it.

**A guard must never guess why it failed.** `get-lifecycle-policy` fails both when
the policy is absent and when the caller lacks permission to read it. Branch on the
error text and report each case separately: send both to `/dev/null` and a missing
*permission* is announced as a missing *policy*, sending the reader to fix something
that is already correct. Four extra lines, and the difference between a guard that
diagnoses and one that misleads.

**The general rule this is an instance of:** when omitting a setup step produces
*no failure* — only slow cost, drift, or silent risk — a checklist entry is not
enough, because the checklist is read once and the pattern is copied forever.
Encode it as an assertion in the pipeline.

**Run the verify against established projects, and against every account — not
only the accounts you work in.** A missing policy never fails a build, so nothing
surfaces it retroactively; the repositories that need it most are the ones in an
account nobody has thought about lately. Enumerate the accounts from the profiles in
`~/.aws/config` rather than from memory, and run the loop in each.

#### 7b — Buildspec traps `[claude]`

Four things bite when authoring a buildspec, each failing in a way that does not name its
cause:

- **The standard CodeBuild image is Amazon Linux, not Ubuntu.** A step that installs a
  `.deb` dies with a bare exit 127. Use the Amazon Linux package manager, or pin an image.
- **The registry cache needs the `docker-container` buildx driver.** `--cache-to
  type=registry` fails outright with "Cache export is not supported for the docker driver"
  unless the buildspec creates and selects a `docker-container` builder first. The cache
  itself lives in the registry, so it is runner-agnostic once the driver is right.
- **A compose service name may not match the deploy target name.** Parameterise it rather
  than assuming they match — the mismatch fails exactly one service in a fleet, at
  `POST_BUILD`, long after the build passed.
- **Mint a fresh deploy key for the host rather than reusing an existing one.** An old key
  usually exists only as an unreadable secret somewhere; a new one lets the old identity be
  deleted outright instead of lingering with standing access.

### 8 — Full verification `[claude]`

Re-run each section's **Verify** block above, top to bottom, and read the output. Resolve anything that reports missing or unset before developing. The machine checks (P0) only need re-running if you changed toolchain since; the project checks (steps 4, 6, 7, 7-prereq, 7a) are the ones that catch a half-finished setup. Step 7a's verify is also worth running periodically against **established** projects — a missing lifecycle policy never fails a build, so nothing else will surface it.

### 9 — First work session `[claude]`

```bash
/work <issue#>     # or bare /work to start a feature branch with no issue
```

`/work` fast-forwards local `main`, cuts a fresh feature branch, links the issue (board → In Progress if configured), and reads the issue so Claude can propose an approach. From here the normal loop is live: `/commit` → `/open-pr` → `/triage` → `/merge` → `/deploy`. See `gitflow-cheatsheet.md`.

---

## What "ready to develop" means

When all nine boxes are checked and every verify block passes: the project has the full `.claude/` ruleset + gitflow subsystem, CI on every PR (commitlint, type-check, Biome, Semgrep, Vitest), Gemini review (if installed), and a proven `/work → /merge → /deploy` pipeline. Start building.

## Related docs

- `gitflow-cheatsheet.md` — the day-to-day command flow once setup is done
- `gemini-code-review-setup.md` — full Gemini Code Assist install (step 5)
- `kit-repo-github-config.md` — repo / GitHub config reference
- `handbook.md` — §0 kit layout, §9 sync workflow, §9.7 substitutions, §11 workflow templates, §6.5 deploy direct-push, §9.4.1 sync does no git

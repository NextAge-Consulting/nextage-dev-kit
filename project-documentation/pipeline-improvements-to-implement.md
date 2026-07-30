# Pipeline Improvements To Implement

Running backlog of kit-pipeline improvements identified but not yet built. The
pipeline template is maintained here in the dev kit; **a designated consumer
project is the testbed** where each change is proven before it propagates.
Each numbered section is a self-contained proposal — validate, implement, then
strike it from this list.

---

---

## 1. Move AWS auth from static IAM keys to GitHub OIDC

**Status:** proposal — not yet implemented.
**Raised:** 2026-07-08 (surfaced while adding the nightly Neon→S3 backup workflow).
**Scope:** kit-level CI-auth pattern. Affects every workflow template that touches AWS and the consumer IAM setup.

### Current model (what the kit does today)

Every AWS-touching workflow authenticates with **long-lived static IAM access
keys** stored as GitHub repo secrets (`AWS_ACCESS_KEY_ID`,
`AWS_SECRET_ACCESS_KEY`), belonging to a single IAM user (e.g.
`github-actions-ecr-push`). In a split-deploy consumer that is one workflow per
app plus `migrate` and `db-backup` — all sharing one key pair via the same `configure-aws-credentials`
block. The user carries `GitHubActionsECRPushPolicy`, `ParameterStoreREADPolicy`,
and (new) `<Project>DBBackupS3Policy`.

### Why change

- **Long-lived credentials.** The static keys never expire on their own; a leak
  (log spill, compromised runner, exfiltrated secret) grants standing AWS access
  until someone manually rotates. Rotation is manual and easy to forget.
- **No per-run / per-branch / per-environment scoping.** Any workflow with the
  secret gets the full permission set. OIDC trust policies can scope by repo,
  branch ref, and GitHub Environment.
- **Industry + AWS + GitHub default.** OIDC (short-lived, per-run tokens minted
  from `token.actions.githubusercontent.com`) is the documented best practice;
  static keys are the legacy path.

### Target model

Replace the static-key `configure-aws-credentials` block with the OIDC
role-assumption form:

```yaml
permissions:
  id-token: write   # required to mint the OIDC JWT
  contents: read
steps:
  - uses: aws-actions/configure-aws-credentials@<pinned-sha>
    with:
      role-to-assume: arn:aws:iam::724168882429:role/github-actions-<repo>
      aws-region: ${{ secrets.AWS_REGION }}
```

### Work required (per account, one-time + per-repo)

1. **IAM OIDC identity provider** for `token.actions.githubusercontent.com`
   (one per AWS account; the `aws-actions` action no longer needs a thumbprint).
2. **IAM role(s)** with a trust policy scoped to the repo
   (`repo:<org>/<repo>:*`, tightened to specific branches/environments
   where possible), carrying the *same* permission policies the static user has
   today (ECR push, SSM read, S3 backup put). Consider splitting: a
   production-deploy role gated by a GitHub `production` Environment vs. a
   lower-privilege role for migrate/backup.
3. **Update every AWS workflow** to add `permissions: id-token: write` and swap
   the credentials block to `role-to-assume`.
4. **Cut over, verify, then delete** the `AWS_ACCESS_KEY_ID` /
   `AWS_SECRET_ACCESS_KEY` secrets and deactivate the static user's access key.

### Open questions / next steps

1. One shared CI role, or split by privilege (deploy vs. migrate/backup) and gate
   the deploy role behind a `production` Environment?
2. Trust-policy `sub` scoping — repo-wide, or per-branch/per-environment?
3. Sequencing: cut over all 7 workflows in one PR (atomic, single verification)
   vs. pilot one (e.g. `db-backup`, lowest blast radius) then fan out.
4. Whether `AWS_ACCOUNT_ID` / `AWS_REGION` stay as secrets (they can — they're
   not credentials) or move to workflow `env`.

### References

- GitHub OIDC with AWS: https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/configuring-openid-connect-in-amazon-web-services
- `aws-actions/configure-aws-credentials` (OIDC usage): https://github.com/aws-actions/configure-aws-credentials#oidc
- AWS: creating OIDC identity providers: https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_providers_create_oidc.html

---

## 2. CI gate for orphaned exports (dead code the current tools cannot see)

**Status:** proposal — not yet implemented. Discussion parked 2026-07-14 before a tool choice was made.
**Raised:** 2026-07-14 (surfaced during consumer feature work).
**Scope:** kit-level CI gate. Node/TypeScript consumers.

### The gap

Nothing in the pipeline detects an export that nothing imports.

- **Biome 2.5.1 has no rule for it.** Every `noUnused*` rule it ships is
  file-scoped: `noUnusedVariables`, `noUnusedImports`,
  `noUnusedFunctionParameters`, `noUnusedPrivateClassMembers`,
  `noUnusedClasses`. None cross the module graph. There is no
  `noUnusedExports`. Verified against the shipped
  `configuration_schema.json`, not from memory.
- **`tsc` is the same.** `noUnusedLocals` is per-file. An exported symbol is
  used by definition, so it is never flagged.
- **Gemini Code Assist reviews a diff.** It has no import graph. "Nothing calls
  this" is not a fact available to it.

The `export` keyword is the thing that hides a symbol from every check we run.

### What it cost (why this is on the list)

Two live instances in one session, both green under the full pipeline:

1. **`apps/property` valve control + accessory attach.** The server functions
   (`submitValveActionFn`, `attachAccessoryFn`) were written, permission-gated,
   and correct. The client handlers were `notPermitted` stubs. Nothing imported
   the server functions, so the buttons showed an error and the requests were
   never sent. Type-check, biome, and review all passed. A fix was made to a
   function nothing called, and it appeared to work because the code was never
   reachable.
2. **`getCustomerSessionExtras` in `apps/shop`.** A `createServerFn` that
   nothing imported — a redundant wrapper over `loadCustomerSessionExtras`,
   which the real session path (`serverAuth.ts`) already uses. A reachable HTTP
   endpoint with no caller. Deleted 2026-07-14. Shop type-checked clean both
   before and after the deletion, which is the whole problem in one sentence.

### Framing (two wrong turns, recorded so they are not repeated)

**Wrong turn 1 — scope the gate to `createServerFn`.** The reasoning was that a
server function exists only to be called, so one with no importer is
unambiguously a bug, and an ad-hoc grep found 142 server functions with exactly
1 orphan. Clean signal, near-zero noise. It was rejected because the scope was
picked to fit the evidence that happened to be in hand, not the problem. The rot
class is orphaned exports generally. A server-function-only gate is also a
TanStack-specific special case in a stack-agnostic kit, needing its own script
and its own maintenance, to catch one instance of a broader rule.

**Wrong turn 2 — dismissing knip's output as noise.** An unconfigured knip run
on a mature consumer returned 106 findings. These were initially called noise on the
grounds that the flagged symbols had references — e.g. `slice1` has 13. That
reasoning is wrong. **"Unused export" is not "unused symbol."** `slice1` is used
13 times inside its own file and zero times outside it. The fix is deleting the
word `export`. That is a true finding of a real problem: an unnecessary export
is a hole cut in the safety net, since exporting is exactly what made
`getCustomerSessionExtras` invisible. 106 findings is not a triage tax. It is
the backlog. The size of the mess is not an argument against measuring it.

### Target model

**Sweep to zero, then gate at zero.**

A gate is only a recurring tax if a backlog is left sitting under it. Clean the
existing findings first — most fixes are deleting one word, some are deleting a
dead function, and a few are declaring a genuine public API as an entry point.
Then turn the gate on. From that point every hit is one new line, caught in the
PR that introduced it, while the author is still looking at it.

This replaces proposal-scope "unused server functions" with the general rule:
**an export that nothing imports is a defect.** Constitution §XII (own all
errors) and the TypeScript rule "TS6133 → DELETE" already say this; there is
simply no tool enforcing it.

### Work required

1. Pick the tool (see open questions) and configure entry points honestly.
2. Sweep the consumer to zero. Expect three fix shapes: drop the `export` keyword,
   delete the symbol, or declare a real entry point.
3. Add the CI job to `ci.yml`, gated on the existing Node stack detection —
   same shape as the `dep-alignment` job.
4. Propagate to other consumers, each doing its own sweep before the gate goes
   live for it.

### Open questions / next steps

1. **Tool.** knip (does the whole class, needs config), `ts-prune` (thinner,
   less maintained), or a home-grown script next to
   `check-dep-alignment.mjs` (no dependency, but we own the module-graph
   parsing, which is the hard part). Note a home-grown grep-based check matches
   symbols textually — a name appearing only in a comment reads as "called."
   Any real implementation must resolve actual import statements.
2. **Config placement — the kit divergence problem.** knip needs entry points,
   and entry points genuinely vary per project (one consumer's `apps/shared`
   barrel is a real public API consumed by six apps; another may have no shared
   package at all). The kit forbids per-consumer variation in
   canonical files. Likely answer: `ci.yml` stays byte-identical and just runs
   the tool, while `knip.json` is a project-local file each consumer owns —
   confirm this fits the sync model before building.
3. **`apps/shared` barrel.** 24 of the 106 findings are its
   re-exports. It is a library API, so those are entry points, not dead code —
   but confirm each one actually has a consumer rather than blanket-excluding
   the file, or the exclusion recreates the blind spot the gate exists to close.
4. **Scope limit — state it plainly.** This gate catches "nothing imports this."
   It does **not** catch a handler wired to the *wrong* function. Instance 1
   above happened to be both. Do not let the gate's existence imply the class is
   fully covered.
5. **Python consumers.** `ruff`'s F401 is file-scoped, same blind spot. Whether
   an equivalent (`vulture`, or `ruff` if it grows project-wide analysis) is
   worth adding is a separate question — do not block the Node gate on it.

### References

- Biome rule list (verified — no unused-export rule): `node_modules/@biomejs/biome/configuration_schema.json`
- knip: https://knip.dev
- Existing home-grown gate precedent: `scripts/check-dep-alignment.mjs` + the `dep-alignment` job in `ci.yml`

---

## 3. Local AWS auth: `aws login` sessions expire between working sessions

### The problem

Profiles are provisioned with `aws login` (browser console sign-in), which caches
an access token plus a refresh token and renews credentials silently *while the
refresh token is valid*. In practice that validity is measured in days, so the
first AWS-touching step of essentially every working session is a re-login.

`aws login` has **no session-duration option** (verified against aws-cli 2.32.7 —
the only flag is `--remote`). The lifetime is tied to the console session and is
not configurable, so there is no cheap knob to turn.

### Why it matters beyond the friction

The delay itself is minor. The real cost is behavioural: faced with an
unavailable session, the assistant has repeatedly **guessed instead of asking** —
asserting that a resource exists or is configured a certain way, and writing that
into docs and reports as though verified. That is the mechanism by which specs go
stale. `cli-utilities.md` now forbids it explicitly and requires an up-front
`sts get-caller-identity` check, but removing the friction removes the temptation.

### Target model

**AWS IAM Identity Center** (successor to AWS SSO), with the access-portal session
duration raised from the 8-hour default. Configurable 15 minutes – **90 days**
(the ceiling rose from 7 to 90 days in Sept 2023). With an `sso-session` profile,
the CLI auto-renews role credentials for the whole portal session, so a login
lasts a quarter rather than a few days.

### Work required

Per account, one-time:

1. Enable IAM Identity Center; choose an identity source.
2. Settings → Authentication → session duration → set the desired maximum.
3. Create a permission set and assign the user to the account.
4. Reconfigure the local profile with `aws configure sso` (writes an
   `sso-session` block); `aws sso login` replaces `aws login`.
5. Update `cli-utilities.md` — the "Profile provisioning" section documents
   `aws login` and would need to describe the SSO flow instead.

### Open questions / next steps

- **Account ownership is the blocker, not the technology.** As of 2026-07 the two
  accounts in play are not the maintainer's to reconfigure: `267651633321` is an
  AWS Organization management account whose master email belongs to a client
  stakeholder, and `724168882429` is standalone but likewise not the maintainer's.
  Enabling Identity Center is an org/identity change that needs the owner's
  agreement — raise it with them rather than assuming it can be done unilaterally.
- Two unrelated accounts means either two Identity Center instances, or bringing
  them under one Organization first. Decide which before starting.
- Confirm whether a 90-day session is acceptable to whoever owns the account's
  security posture; the default is 8 hours for a reason, and a long-lived portal
  session is a genuine trade-off, not a free win.

### References

- `aws login --help` (aws-cli 2.32.7) — no duration flag
- Session duration 15 min – 90 days: https://docs.aws.amazon.com/singlesignon/latest/userguide/user-interactive-sessions.html
- Limit increase 7 → 90 days: https://aws.amazon.com/about-aws/whats-new/2023/09/aws-iam-identity-center-session-duration-limit-increases/
- CLI SSO configuration + automatic token refresh: https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-sso.html

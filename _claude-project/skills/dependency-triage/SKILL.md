---
name: dependency-triage
description: The weekly dependency and vulnerability pass — find what is vulnerable (npm audit) and what is behind (npm outdated), decide each by blast-radius tier, take updates past their cooldown through gitflow like any other change, record exceptions for what cannot be fixed, and check Node LTS. Executes project-documentation/dependency-policy.md. Assumes the kit pipeline (gitflow + /deploy + CI-does-NOT-build). Use when the user asks for "dependency triage", "weekly deps", "check vulnerabilities", "update dependencies", "npm audit", or when /deploy names a vulnerability. Triggers: "dependency triage", "weekly deps", "check vulnerabilities", "check advisories", "update dependencies".
allowed-tools: Bash(gh:*), Bash(git status:*), Bash(git log:*), Bash(git fetch:*), Bash(npm:*), Bash(docker:*), Bash(lsof:*), Bash(curl:*), Bash(jq:*), Bash(grep:*), Read, Glob, Grep
---

# dependency-triage — the weekly dependency + vulnerability pass

Claude does the analysis, the updates and the verification; the human decides each
exception and lands the work through `/commit`. **Read
`project-documentation/dependency-policy.md` first** — its timelines, its exceptions
table, its build-graph additions and its project notes. If it is missing, say so: the
project has not decided its timelines yet.

**No bot opens dependency PRs.** Every update this pass makes lands in the working tree
of the branch the session is on and reaches `main` through `/commit`, `/open-pr` and
`/merge` — the full suite, the build gate and review, like any other change. Never run
`gh pr merge` on a dependency branch.

## The one fact that drives the tiers

**PR CI does not build the app.** `ci.yml` type-checks, lints and tests; the
production build runs only in `/merge` and in the deploy image. So a build-graph update
that type-checks and tests green can still break the build — and once on `main`, it
fails every later `/merge` on damage it did not cause. Build-graph updates are built and
run in the real deploy image before the PR opens. Leaf updates are not.

| Tier | What | Gate |
|---|---|---|
| **Leaf** | runtime and dev libraries outside the build graph | the full suite |
| **Build graph** | the policy's kit list, its project additions, and anything else in the bundler, framework, router, server adapter, CSS pipeline or database driver | the full suite **+** the deploy image built and run, with a real sign-in |

Update build-graph packages one family at a time — the TanStack set together, React
with its types — so a failure names its cause.

## 1. Find what needs doing

```bash
npm audit --json | jq -r '.vulnerabilities | to_entries[] |
  "\(.value.severity)\t\(.key)\tdirect=\(.value.isDirect)\tfix=\(.value.fixAvailable | if type=="object" then "\(.name)@\(.version)\(if .isSemVerMajor then " MAJOR" else "" end)" else tostring end)"'
npm outdated --all --json
```

`npm audit` is the vulnerability list whether or not the project turned GitHub's alerts
on — read the alerts tab too when it did, since it carries the advisory's history. For
each advisory, `npm audit --json`'s `via` gives the `GHSA-…` id the exceptions table uses,
and `npm why <pkg>` names what pulls a transitive package in.

Then the project notes' own checks (a pinned release-candidate `npm outdated` cannot see,
for example), and the Node LTS check:

```bash
curl -s https://raw.githubusercontent.com/nodejs/Release/main/schedule.json | jq -r --arg d "$(date +%F)" \
  'to_entries[] | select(.value.lts != null and .value.lts <= $d and $d <= .value.maintenance) | .key | ltrimstr("v")'
jq -r .node.major .claude/stack-manifest.json
```

The first names the Active LTS major; the second is the kit's. When they differ, the
kit moves every project at once with a migration — report it, never change a
project's Node major here.

## 2. Decide each

**A vulnerability with a fix:**
- **In a direct dependency** — update it, by its tier.
- **In a transitive one** — update the DIRECT dependency that pulls it in to a release
  that carries the fix. Never force the transitive one with an override: a version its
  parent was not built against is how fixing a finding breaks an app.
- **Only reachable through a major** — a major is a build-graph-sized change whatever
  the package; read its migration notes before taking it.

**A vulnerability with no fix** — none published, or the parent has not released one —
gets a row in the policy's exceptions table: the `GHSA-…` id, the package, why it
cannot be fixed now, who approved it (ask; never fill it yourself), and a review date
inside the policy's window. `/deploy` reads that table.

**An outdated package with no vulnerability** — take patches and minors that are past
their cooldown; leave a major for when its migration notes have been read and the work
is wanted, and say so.

**The cooldown, every time.** Take a version only once it has been published for 3 days
(a patch), 7 (a minor) or 30 (a major):

```bash
npm view <pkg> time --json | jq -r --arg v <version> '.[$v]'
```

Younger than that: take the newest release that is past it, or leave the update for
the next pass. A security fix gets the same cooldown — read what changed before taking
it.

## 3. Update and verify

1. **Install from the lockfile first**, so the baseline is the project's: `npm ci`, then
   the full suite. A red baseline is fixed before any update.
2. **Make the updates**: `npm install --save-exact <pkg>@<version>` in every workspace
   that declares the package — one version per shared dependency, which `dep-alignment`
   enforces.
3. **Leaf**: the full suite.
4. **Build graph**: the full suite, then build the real deploy image for the heaviest
   app and any app whose config diverges, run it on its native port, and complete a
   real sign-in — never "200 on a route" or "server ready" in the log; auth and crypto
   load lazily, so a boot can succeed while every request fails. The build and run
   commands come from the project's `Dockerfile.*` and deploy workflows — discover them,
   do not assume. Full standard: the kit's `project-documentation/dependency-management.md` §5.
5. **Install scripts**: a new package or version that wants to run one is surfaced for
   the human's approval (`dependencies.md` §III).

## 4. Hand back

- What was updated, by tier, and how each was verified.
- What was left and why — a cooldown not yet passed, a major not yet wanted.
- Each exception proposed, for the human to approve and name.
- Under `ASSURANCE_LEVEL` `strict`, a row for the policy's pass log: the date, what was
  found, what was decided, who decided it.
- The work lands through `/commit`, on the human's word.

## Guardrails

- **Never `/deploy`, `/ship-main` or `/commit` as part of the pass** — the human
  triggers them.
- **Never take a version inside its cooldown**, security fix or not.
- **Never change the Node major or a kit-pinned version's floor here** — both are the
  kit's (`.claude/stack-manifest.json`). A project may run a pinned package newer than
  the kit's version; never older.
- **Never approve an exception yourself.** Propose it; the human approves and is named.

# Dev Kit Workflow

> **Companion:** `sync-design-pre-read.md` — what to read before recommending or executing any kit change. Read both when working on the kit.

The kit is a project like any other, with its own `.claude/` of rules, hooks, skills and kit-custom commands. What distinguishes it is that `_claude-project/` is the template source for every OTHER project's `.claude/`.

## The three source surfaces

**`_claude-project/`** is what syncs out to consumer `<project>/.claude/` via `/sync-dev-kit`: rules, hooks, skills, the gitflow commands, agents, `settings.json`, `templates/`. Changes here reach every consumer on their next sync.

**`_claude-global/`** holds `commands/work.md`, installed to `~/.claude/` by `/install-kit`. Every dev gets this tier. `work` is the session-init command, launched from the "claude agents" view before the session is inside any repo, so it has to exist globally to exist at launch time. It is project-agnostic and hardcoded to none; its `work.sh` ships via `_claude-project` and resolves once the session is in the project. Every other kit command only makes sense inside a project, so they ship per-project.

**`_claude-maintainer/`** holds `kit-maintainer.md`, `commands/sync-dev-kit.md` and `scripts/sync-dev-kit.sh`, installed to `~/.claude/` by `/install-kit --maintainer`. Only the maintainer's machine gets this tier. `sync-dev-kit` must run from any project directory, so it is global by necessity — but it ships here rather than in `_claude-global/` because the maintainer syncs projects ahead of the other devs, and a consumer machine that could sync would clobber that work. Withholding the script beats guarding it: absent tooling has nothing to bypass.

`kit-maintainer.md` is inert unless `~/.claude/CLAUDE.md` imports it (`@kit-maintainer.md`), and the separate `~/.claude/kitmaster` marker is what makes `block-kit-edit.sh` inert. Both are per-machine and deliberately unshipped; `--maintainer` warns when either is missing and never creates them.

`_statusline/statusline.sh` installs to `~/.claude/statusline.sh` via `/install-statusline`, one time. It is an asset, not a command.

## The kit's own `.claude/`

The kit repo's project-level config, loaded when working in the kit. It holds the part of `_claude-project/` the kit actually uses — gitflow commands, the shared rules, hooks and skills — which is everything the manifest below does not mark template-only. The manifest governs; a large slice is deliberately absent.

It also holds kit-custom items that never propagate: the `install-kit`, `install-cpl` and `install-statusline` commands, and the kit-specific rules `dev-kit-workflow.md` and `sync-design-pre-read.md`. Edit those in place — they have no other home, and the "kit's own rule tweak" row below does not apply to them.

Those prove the extensibility pattern: any project can add commands in its own `.claude/commands/` that the kit knows nothing about.

## Propagation

| Change to | Propagate to |
|-----------|--------------|
| `_claude-project/*` | Mirror into the kit's `.claude/` so the kit itself uses it — **unless the item is template-only** per the manifest below. Commit both surfaces when mirrored. |
| `_claude-global/*` | Edit the kit source AND `~/.claude/` in the SAME pass; `diff` to prove byte-identical. |
| `_claude-maintainer/*` | Edit the kit source AND `~/.claude/` in the SAME pass; `diff` to prove byte-identical. |
| `_statusline/statusline.sh` | Edit the kit source AND `~/.claude/statusline.sh` in the SAME pass; `diff` to prove byte-identical. `/install-statusline` is bootstrap, not propagation. |
| Kit-custom command or rule in `.claude/` | Lives only there — edit in place. Do not move to `_claude-project/`, do not install globally. |
| Kit's own tweak to a SHARED rule | Copy to `_claude-project/rules/` if it applies to every project; leave it in `.claude/rules/` if it is about the kit's own machinery. |

"Commit both surfaces" means one commit containing both, so the kit is never at a state where source and dogfood disagree.

**`/install-kit` is the bootstrap for a NEW machine, never the propagation step** — the same distinction as `/sync-dev-kit`, which is how consumer machines pull and never how the maintainer pushes. Re-running the installer to deliver an edit leaves the change half-applied until someone remembers to run it.

## Kit dogfood manifest (single source of truth)

The kit dogfoods only what it actually uses. Everything below ships to consumers via `_claude-project/` but makes no sense for the kit itself, so it is **template-only** and deliberately absent from the kit's `.claude/`. This table is the single authority; `sync-design-pre-read.md` and handbook §12a.7 point here rather than keeping copies.

| Template-only item (`_claude-project/…`) | Why the kit doesn't dogfood it |
|-------------------------------------------|--------------------------------|
| `commands/deploy.md`, `skills/gitflow/scripts/deploy.sh` | Kit has nothing to deploy — no version artifact, no deploy target. |
| `commands/dev.md`, `skills/dev-server/**` | Kit has no dev server / runnable app. |
| `skills/design-system/**`, `rules/ui-design.md`, `rules/a11y-baseline.md` | Kit has no UI — no JSX/TSX, no `design.md` (handbook §12a.7). |
| `skills/ui-patterns/**`, `rules/ui-patterns.md` | Kit has no UI — nothing to compose and no interactions to pattern. |
| `templates/dependency-policy.md` | Operating procedure for acting on Dependabot output. The kit has no `package.json` and no dependencies, so there is nothing to triage and no timelines to own. Syncs to consumers in `template` mode (handbook §11.10b). |
| `templates/ui-inventory.md` | Seed for a consumer's `rules/project/ui-inventory.md` — an enumeration of that project's own components. Kit has no UI, so there is nothing to enumerate. |
| `skills/shadcn/**` | Kit has no `components.json` / shadcn install. |
| `skills/mfing-bible-of-tanstack/**` | Kit has no TanStack code. |
| `tanstack-manifest.json` | Kit-blessed TanStack versions + vendored-reference provenance. Kit has no `package.json` and no TanStack dependency. Consumed by the (also template-only) `scripts/check-tanstack.mjs`. |
| `rules/postgres-drizzle.md`, `skills/postgres-neon-drizzle/**` | Kit has no database, no Drizzle schema and no Neon project. |
| `rules/cli-utilities.md` | Kit runs no AWS / cloud CLI — the account/region discipline never applies. |
| `skills/agent-browser/**`, `rules/integrations/agent-browser.md` | Kit has no web app to drive a browser against. |
| `skills/e2e/**` | Kit has no `test/e2e/*.md` flow files. |
| `templates/testing/**` | Kit has no `package.json`, no vitest, no Neon project. They sync to consumers in `template` mode via `SHARED_MODULE_DIR` (handbook §11.13); the kit is not a consumer of them. |
| `skills/e2e-author/**` | Kit has no flow files to author. |
| `skills/analysis/**` | Kit produces markdown analyses of itself in-repo; the shareable-HTML analysis workflow is for consumer apps. |
| `lib/gen-report.mjs` | Shared report generator invoked by the (template-only) e2e + analysis skills; the kit runs neither. |
| `rules/dev-server.md` | Companion to the (excluded) dev-server feature; kit runs no dev servers. |
| `rules/dependencies.md` | Kit has no `package.json` — nothing to install, no lockfile to protect. |
| `skills/dependency-triage/**` | Kit has no `package.json` and no `.github/dependabot.yml` — no dependency PRs are ever opened here. |
| `templates/scripts/**` | Seeds for a consumer's `scripts/` — `check-dep-alignment.mjs`, `check-workspace-tiers.mjs`, `check-tanstack.mjs`, `db-branch.mjs`. The first three read a `package.json` / workspace graph the kit does not have; the fourth resolves a Neon branch, and the kit has no database. |
| `rules/project/README.md` | Consumer scaffolding placeholder; the kit has its own `rules/project/` content. |

Anything in `_claude-project/` not listed above IS dogfooded. Kit-custom items (`install-*`, `dev-kit-workflow.md`, `sync-design-pre-read.md`) live only in the kit's `.claude/` and are governed by the propagation table, not this one.

### Present but unwired: three guards the kit tests without running

`hooks/block-kit-edit.sh`, `hooks/dev-server-guard.sh` and `hooks/npm-guard.sh` are mirrored into the kit's `.claude/hooks/` but deliberately **absent from the kit's `settings.json`**, so the kit never executes them. They are there as test subjects: the sibling-suite convention (`hook-testing.md`) locates `X.test.sh` next to `X`, and a guard cannot be tested unless the file is present.

Their behaviour still makes no sense inside the kit, which is why they are not wired. `block-kit-edit.sh` guards a consumer against editing kit-synced files, and the kit IS the source with no `.kit-sync.json` to read; the other two guard a dev server and a `package.json` the kit does not have.

**So for these three the dogfood test is the `settings.json` wiring, not presence in `.claude/hooks/`.** Adding a wiring for any of them changes a decision rather than fixing a bug.

### Every new kit item needs a conscious dogfood decision

When any new command, skill, hook or rule is added to `_claude-project/`, make and record the decision in the same change. Dogfooded means mirror it into the kit's `.claude/` and commit both surfaces. Template-only means add a row to the table above with the reason and do not mirror it. "I forgot to decide" is the failure this prevents.

## The kit is a baseline, not compliance enforcement

`/sync-dev-kit` offers diffs for the user to accept, reject or merge. Consumer projects can consciously diverge: project-specific rules in `<project>/.claude/rules/project/`, project-specific skills and commands, custom hooks beyond what the kit provides. The kit maintains a baseline; divergence is expected where it makes sense.

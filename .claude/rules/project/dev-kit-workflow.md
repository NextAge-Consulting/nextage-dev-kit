# Dev Kit Workflow

> **Companion:** `sync-design-pre-read.md` — what to read before recommending or executing any kit change. Read both when working on the kit.

The kit is a project like any other, with its own `.claude/` of rules, hooks, skills and kit-custom commands. What distinguishes it is that `_claude-project/` is the template source for every OTHER project's `.claude/`.

## The two source surfaces

**`_claude-project/`** is what syncs out to consumer `<project>/.claude/` via `/sync-dev-kit`: rules, hooks, skills, the gitflow commands, `/sync-dev-kit` itself and its launcher script, agents, `settings.json`, `templates/`. Changes here reach every consumer on their next sync.

**`_claude-maintainer/`** never syncs into a project. It holds:

- `sync/` — the sync engine, its suite and the procedure `/sync-dev-kit` follows. Every project's launcher runs them from the kit clone named by `devKitPath`, so a sync always runs the kit's current engine.
- `migrations/` — each a `PROMPT.md`, and sometimes a codemod it reaches through `devKitPath`, that `/sync-dev-kit` runs in a project's session for every migration the kit added since that project last synced. `rules/project/migrations.md` is how one is written.
- `kit-maintainer.md`, `commands/review-stack.md` and `scripts/review-stack.sh` — the maintainer's own surface, copied to `~/.claude/` by hand when setting up a maintainer machine (`kitmaintainer-handbook.md` §0.1).

**Whoever holds a project's keys syncs it, with the project's own `/sync-dev-kit`.** A team's syncer takes the kit's latest release on their own schedule; the maintainer syncs only the projects whose keys they hold. Only the maintainer changes the kit.

**There is no global tier for consumers.** Every kit command ships per-project via `_claude-project/commands/`, `/work` and `/sync-dev-kit` included. A command file in `~/.claude/commands/` outranks the project's copy of the same name, so a global command cannot be updated by `/sync-dev-kit` and silently shadows the project's copy forever. `work.sh` refuses to run when it finds a global `work.md` or `sync-dev-kit.md`, and that guard is the only reliable place to catch one: nothing else runs on every invocation.

`kit-maintainer.md` is inert unless `~/.claude/CLAUDE.md` imports it (`@kit-maintainer.md`), and the separate `~/.claude/kitmaster` marker is what makes `block-kit-edit.sh` inert and lets the launcher sync from the kit's working tree. Both are per-machine and deliberately unshipped.

`_statusline/statusline.sh` installs to `~/.claude/statusline.sh` via `/install-statusline`, one time. It is an asset, not a command.

## The kit's own `.claude/`

The kit repo's project-level config, loaded when working in the kit. It holds the part of `_claude-project/` the kit actually uses — gitflow commands, the shared rules, hooks and skills — which is everything the manifest below does not mark template-only. The manifest governs; a large slice is deliberately absent.

It also holds kit-custom items that never propagate: the `install-cpl`, `install-statusline` and `shipkit` commands, `scripts/shipkit.sh`, the kit-specific rules `dev-kit-workflow.md`, `sync-design-pre-read.md`, `hook-testing.md` and `migrations.md`, and the pre-ship gate — `project-gate.sh` and `kit-gate/` (kitmaintainer-handbook.md §9.11). Edit those in place — they have no other home, and the "kit's own rule tweak" row below does not apply to them.

Those prove the extensibility pattern: any project can add commands in its own `.claude/commands/` that the kit knows nothing about.

**The kit repo's root `.github/` is the kit's own automation and never syncs** — the pin watch (kitmaintainer-handbook.md §9.13). What consumers receive is `_github-project/`. Edit it in place.

## Propagation

| Change to | Propagate to |
|-----------|--------------|
| `_claude-project/*` | Mirror into the kit's `.claude/` so the kit itself uses it — **unless the item is template-only** per the manifest below. Commit both surfaces when mirrored. |
| `_claude-maintainer/{kit-maintainer.md,commands,scripts}` | Edit the kit source AND `~/.claude/` in the SAME pass; `diff` to prove byte-identical. |
| `_claude-maintainer/{sync,migrations}` | Lives only in the kit — every launcher runs it from the clone. Edit in place. |
| `_statusline/statusline.sh` | Edit the kit source AND `~/.claude/statusline.sh` in the SAME pass; `diff` to prove byte-identical. `/install-statusline` is bootstrap, not propagation. |
| Kit-custom command or rule in `.claude/` | Lives only there — edit in place. Do not move to `_claude-project/`, do not install globally. |
| Kit's own tweak to a SHARED rule | Copy to `_claude-project/rules/` if it applies to every project; leave it in `.claude/rules/` if it is about the kit's own machinery. |

"Commit both surfaces" means one commit containing both, so the kit is never at a state where source and dogfood disagree.

**Everything reaches the kit's `main` through `/shipkit`,** which commits, opens the PR with the release notes, merges, and publishes the dated release the projects sync. `/ship-main` does not ship the kit: the pre-ship gate refuses on `main`.

**Setting up a maintainer machine is a one-time manual copy, documented as prose in `kitmaintainer-handbook.md` §0 — never a command.** It happens twice in the kit's life (a new machine, or someone taking over a fork), and a dedicated command for that is a maintenance surface earning nothing. Propagation is editing both copies in the same pass, as the table above says; a setup procedure is not propagation, and reaching for one to deliver an edit leaves the change half-applied.

## Kit dogfood manifest (single source of truth)

The kit dogfoods only what it actually uses. Everything below ships to consumers via `_claude-project/` but makes no sense for the kit itself, so it is **template-only** and deliberately absent from the kit's `.claude/`. This table is the single authority; `sync-design-pre-read.md` and kitmaintainer-handbook.md §12a.7 point here rather than keeping copies.

| Template-only item (`_claude-project/…`) | Why the kit doesn't dogfood it |
|-------------------------------------------|--------------------------------|
| `commands/deploy.md`, `skills/gitflow/scripts/deploy.sh`, `deploy-org.sh` and their suites | Kit has nothing to deploy — no version artifact, no deploy target, no Terraform. |
| `commands/dev.md`, `skills/dev-server/**` | Kit has no dev server / runnable app. |
| `skills/design-system/**`, `rules/ui-design.md`, `rules/a11y-baseline.md` | Kit has no UI — no JSX/TSX, no `design.md` (kitmaintainer-handbook.md §12a.7). |
| `skills/claude-design/**`, `commands/ui-design.md` | Kit has no UI package and no design system to publish to Claude Design. |
| `commands/design-audit.md` | Kit has no design system or UI code to audit. |
| `skills/ui-patterns/**`, `rules/ui-patterns.md` | Kit has no UI — nothing to compose and no interactions to pattern. |
| `templates/dependency-policy.md` | Operating procedure for acting on Dependabot output. The kit has no `package.json` and no dependencies, so there is nothing to triage and no timelines to own. Syncs to consumers in `merge` mode: the owners, timelines and project-notes regions are the project's (pipeline.md §3.5). |
| `templates/ui-inventory.md` | A consumer's `rules/project/ui-inventory.md`, synced in `merge` mode — the project's own components and patterns live in its regions. Kit has no UI, so there is nothing to enumerate. |
| `templates/design-system/**` | Lands inside the consumer's UI package (`DESIGN_UI_PACKAGE`). Kit has no UI package — its `DESIGN_UI_PACKAGE` is empty. |
| `skills/shadcn/**` | Kit has no `components.json` / shadcn install. |
| `skills/mfing-bible-of-tanstack/**` | Kit has no TanStack code. |
| `stack-manifest.json` | Every version the kit blesses, each with the condition it applies under — `whenDeclared` (the library standard), `whenFile` (a kit-shipped config implies its tool), `whenResolved` (a package the kit's own choices drag in, transitively). Plus vendored-reference provenance. Kit has no `package.json`, no lockfile and no TanStack dependency, so none of the triggers could fire here. Consumed by the (also template-only) `scripts/check-stack.mjs`. |
| `rules/drizzle.md`, `rules/postgres-drizzle.md`, `rules/sqlserver-drizzle.md`, `skills/postgres-neon-drizzle/**` | Kit has no database of any engine and no `drizzle-orm` — its own `DB_ENGINE` is `None`, which stands the engine rules down, and the Drizzle rule's gate finds no declaration. |
| `rules/cli-utilities.md` | Kit runs no AWS / cloud CLI — the account/region discipline never applies. |
| `skills/terraform/**` | Kit has no AWS account and no Terraform — nothing to plan, adopt or document. |
| `skills/agent-browser/**`, `rules/integrations/agent-browser.md` | Kit has no web app to drive a browser against. |
| `skills/e2e/**` | Kit has no `test/e2e/*.md` flow files. |
| `templates/testing/**` | Kit has no `package.json`, no vitest, no Neon project. They sync to consumers via `SHARED_MODULE_DIR` — kit-owned, except the `project.ts` seed (testing.md §1); the kit is not a consumer of them. |
| `skills/e2e-author/**` | Kit has no flow files to author. |
| `skills/analysis/**` | Kit produces markdown analyses of itself in-repo; the shareable-HTML analysis workflow is for consumer apps. |
| `lib/gen-report.mjs` | Shared report generator invoked by the (template-only) e2e + analysis skills; the kit runs neither. |
| `rules/dev-server.md` | Companion to the (excluded) dev-server feature; kit runs no dev servers. |
| `rules/dependencies.md` | Kit has no `package.json` — nothing to install, no lockfile to protect. |
| `skills/dependency-triage/**` | Kit has no `package.json` and no `.github/dependabot.yml` — no dependency PRs are ever opened here. |
| `templates/knip.config.ts` | The kit's unused-code configuration. It reads a root `package.json` and the workspaces it declares; the kit has neither, and no JavaScript to analyse. |
| `templates/scripts/**` | Seeds for a consumer's `scripts/` — `check-dep-alignment.mjs`, `check-workspace-tiers.mjs`, `check-stack.mjs`, `db-branch.mjs`, `check-integration-coverage.mjs`. The dependency, tier and stack checks read a `package.json` / workspace graph the kit does not have; the branch resolver and the coverage check need a database, and the kit has none. |
| `rules/project/README.md` | Consumer scaffolding placeholder; the kit has its own `rules/project/` content. |
| `commands/sync-dev-kit.md`, `scripts/sync-dev-kit.sh` and its suite | The launcher syncs a project from the kit clone; the engine refuses to run inside the kit itself. |

Anything in `_claude-project/` not listed above IS dogfooded. Kit-custom items (listed under "The kit's own `.claude/`") live only in the kit's `.claude/` and are governed by the propagation table, not this one.

### The kit's `settings.json` is the template's

**The kit's `.claude/settings.json` matches `_claude-project/settings.json`, every hook wired.** A guard with nothing to guard here stands down on its own: `block-kit-edit.sh` under the `~/.claude/kitmaster` marker, `dev-server-guard.sh` and `npm-guard.sh` with no dev server or lockfile. Wire the kit differently only when a hook would break the kit itself.

### Every new kit item needs a conscious dogfood decision

When any new command, skill, hook or rule is added to `_claude-project/`, make and record the decision in the same change. Dogfooded means mirror it into the kit's `.claude/` and commit both surfaces. Template-only means add a row to the table above with the reason and do not mirror it. "I forgot to decide" is the failure this prevents.

**Decide in the same change whether an org repo receives it.** An item that only makes sense with application code goes into `is_app_only()` in `sync-dev-kit.sh` (kitmaintainer-handbook.md §9.12).

## Doc audiences

**Every doc is written for one audience: people working WITH the kit, or the maintainer working ON it.** A doc for a consumer's developer, designer or DevOps engineer never tells them how to change the kit; how the kit is built and changed goes only in the maintainer's docs.

| Doc | Reader |
|---|---|
| `overview.md` | Everyone — the build-and-ship loop and which guide is yours |
| `developer-handbook.md`, `designer-handbook.md`, `devops-handbook.md` | One role each; short, the why and the loop, pointing to reference |
| `*-cheatsheet.md` | One role's commands, one page; `kit-sync-cheatsheet.md` is for a project's kit syncer |
| `windows-handbook.md` | A developer on Windows — the machine setup the kit's hooks need |
| Setup and pattern references (`new-project-setup.md`, `infrastructure.md`, …) | Handed to an AI to walk a human through; a rule may cite one |
| `kitmaintainer-handbook.md`, `kit-repo-github-config.md`, `hook-patterns.md` | The kit maintainer |

**An instruction for the AI goes in a rule, skill or command, never in `project-documentation/`** — the folder neither syncs nor loads.

**A role's guide is named `<role>-handbook.md`; nothing else takes that suffix.** A new doc names its reader in its opening line and joins its role guide's pointers.

## The kit is a baseline, not compliance enforcement

`/sync-dev-kit` offers diffs for the user to accept, reject or merge. Consumer projects can consciously diverge: project-specific rules in `<project>/.claude/rules/project/`, project-specific skills and commands, custom hooks beyond what the kit provides. The kit maintains a baseline; divergence is expected where it makes sense.

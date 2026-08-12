# Dev Kit Workflow

> **Companion rule:** `sync-design-pre-read.md` (this folder) — covers the pre-read requirements before recommending or executing any kit change. Read both when working on the kit.

The kit is a project like any other — it has its own `.claude/` with rules, hooks, skills, and kit-custom commands. What distinguishes the kit is that its `_claude-project/` folder is the template source for every OTHER project's `.claude/`.

## The three source surfaces

### `_claude-project/` — Template for consumer projects

Source for what gets synced OUT to consumer `<project>/.claude/` via `/sync-dev-kit`. Contains content every project should have a baseline of: rules, hooks, skills, the gitflow commands (`/commit`, `/checkpoint`, `/open-pr`, `/merge`), agents, `settings.json`, `templates/`.

**Changes here affect every consumer project on next sync.**

### `_claude-global/` — Global bootstrap (consumer tier)

`commands/work.md`. Installed to `~/.claude/` via `/install-kit`. **Every dev gets this tier.**

`work` is the session-init command. It is launched from the "claude agents" view (or `@{project}`) *before* the session is inside any repo; it then starts the body of work in the chosen project. If it weren't global it wouldn't exist at launch time. `work.md` itself is fully project-agnostic — it works *on* a project but is hardcoded to none; its `work.sh` script is project-level (shipped via `_claude-project`) and resolves once the session is in the project.

Every OTHER kit command (`/commit`, `/checkpoint`, `/merge`, etc.) is per-project (ships via `_claude-project/commands/`, synced into each consumer's `.claude/commands/`) — those only make sense once you're already inside a project, so they don't need to be global.

### `_claude-maintainer/` — Maintainer surface

`kit-maintainer.md` + `commands/sync-dev-kit.md` + `scripts/sync-dev-kit.sh`. Installed to `~/.claude/` via `/install-kit --maintainer`. **Only the kit maintainer's machine gets this tier.**

`sync-dev-kit` is global by necessity — it must run from any project directory — but it ships here, not in `_claude-global/`, because the maintainer syncs projects ahead of the other devs. A consumer machine that could sync would clobber that work. Withholding the script beats guarding it: absent tooling has nothing to bypass.

`kit-maintainer.md` is inert unless `~/.claude/CLAUDE.md` imports it (`@kit-maintainer.md`), and the separate `~/.claude/kitmaster` marker is what makes `block-kit-edit.sh` go inert. Both are per-machine and deliberately NOT shipped; `--maintainer` warns when either is missing but never creates them.

### `_statusline/statusline.sh`

Custom statusline asset. Installed to `~/.claude/statusline.sh` via `/install-statusline` (one-time). Not a command or script — just a file.

## The kit's own `.claude/`

This is the kit repo's project-level config, loaded when working IN the kit. Contains:

- **Mirror of `_claude-project/`**: gitflow commands, rules, hooks, skills — same as every other project, so working on the kit has the same baseline behavior.
- **Kit-custom commands and scripts** that never propagate: `install-kit`, `install-cpl`, `install-statusline` (commands + helper `.sh` scripts where applicable). These are the kit's tools for its own maintenance.

This proves the extensibility pattern: any project can add its own custom commands in `.claude/commands/` that aren't in `_claude-project/`. A consumer project could add a `/deploy-myapp` command the kit knows nothing about.

## Propagation rules

| Change to | Propagate to |
|-----------|--------------|
| `_claude-project/*` | Mirror to kit's `.claude/` so the kit itself uses the update **— UNLESS the item is in the "Not dogfooded by the kit" table below**, in which case it is template-only and must NOT be mirrored. Commit both surfaces when mirrored. |
| `_claude-global/*` | Edit the kit source AND `~/.claude/` in the SAME pass, `diff` to prove byte-identical. |
| `_claude-maintainer/*` | Edit the kit source AND `~/.claude/` in the SAME pass, `diff` to prove byte-identical. |
| Kit-custom command in `.claude/commands/` (e.g., `install-kit.md`) | Lives only in kit's `.claude/`. Do not move to `_claude-project/`. Do not install globally. |
| Kit's own rule tweak | If generic, copy to `_claude-project/rules/`. If kit-specific, leave in `.claude/rules/`. |

**`/install-kit` is the bootstrap for a NEW machine, never the propagation step** — the same distinction as `/sync-dev-kit`, which is how consumer machines pull and never how the maintainer pushes. Re-running the installer to deliver an edit leaves the change half-applied until someone remembers to run it, and a machine running instructions the kit no longer holds is exactly the drift these surfaces exist to prevent.

## Kit dogfood manifest (single source of truth)

The kit dogfoods (mirrors into its own `.claude/`) only what it actually *uses*. Items below ship to consumers via `_claude-project/` but make no sense for the kit itself — they are **template-only** and are deliberately ABSENT from the kit's `.claude/`. This table is the **single authority**: `sync-design-pre-read.md` and HANDBOOK §12a.7 point here, they do not maintain their own copies.

| Template-only item (`_claude-project/…`) | Why the kit doesn't dogfood it |
|-------------------------------------------|--------------------------------|
| `commands/deploy.md`, `skills/gitflow/scripts/deploy.sh` | Kit has nothing to deploy — no version artifact, no deploy target. |
| `commands/dev.md`, `skills/dev-server/**` | Kit has no dev server / runnable app. |
| `skills/design-system/**`, `rules/ui-design.md`, `rules/a11y-baseline.md` | Kit has no UI — no JSX/TSX, no `design.md` (HANDBOOK §12a.7). |
| `skills/ui-patterns/**`, `rules/ui-patterns.md` | Kit has no UI — nothing to compose and no interactions to pattern. |
| `templates/ui-inventory.md` | Seed for a consumer's `rules/project/ui-inventory.md` — an enumeration of that project's own components and patterns. Kit has no UI, so there is nothing to enumerate. |
| `skills/shadcn/**` | Kit has no `components.json` / shadcn install. |
| `skills/mfing-bible-of-tanstack/**` | Kit has no TanStack code. |
| `tanstack-manifest.json` | Kit-blessed TanStack versions + vendored-reference provenance. Kit has no `package.json` and no TanStack dependency, so there is nothing here to pin. Consumed by the (also template-only) `scripts/check-tanstack.mjs`. |
| `rules/postgres-drizzle.md`, `skills/postgres-neon-drizzle/**` | Kit has no database, no Drizzle schema and no Neon project — the whole stack never applies. |
| `rules/cli-utilities.md` | Kit runs no AWS / cloud CLI — the account/region discipline never applies here. |
| `skills/agent-browser/**`, `rules/integrations/agent-browser.md` | Kit has no web app to drive a browser against. |
| `skills/e2e/**` | Kit has no `test/e2e/*.md` flow files. |
| `templates/testing/**` | Kit has no `package.json`, no vitest, no Neon project — nothing to test and no deps for these files to resolve against. They sync to consumers in `template` mode via `SHARED_MODULE_DIR` (HANDBOOK §11.13); the kit is not a consumer of them. |
| `skills/e2e-author/**` | Kit has no flow files to author. |
| `skills/analysis/**` | Kit produces markdown analyses of itself in-repo; the shareable-HTML analysis workflow is for consumer apps, not the kit. |
| `lib/gen-report.mjs` | Shared report generator invoked by the (template-only) e2e + analysis skills; the kit runs neither, so it never executes here. |
| `rules/dev-server.md`, `hooks/dev-server-guard.sh` | Companion to the (excluded) dev-server feature; kit runs no dev servers. Excluding the guard also drops its two `settings.json` wirings. |
| `rules/dependencies.md`, `hooks/npm-guard.sh` | Kit has no `package.json` — nothing to install, no lockfile to protect, so the install-discipline rule and its guard never apply. Excluding the guard also drops its two `settings.json` wirings. |
| `rules/project/README.md` | Consumer scaffolding placeholder; the kit has its own `rules/project/` content. |
| `hooks/block-kit-edit.sh` | Consumer-protection guard — denies edits to kit-synced files. Nonsensical inside the kit: the kit IS the source, not a consumer, and has no `.kit-sync.json` to guard. The maintainer exemption (`~/.claude/kitmaster`) makes it inert here anyway. |

Anything in `_claude-project/` NOT listed above IS dogfooded (gitflow, the shared rules/hooks, the general commands). Kit-custom items (`install-*`, `dev-kit-workflow.md`, `sync-design-pre-read.md`) live only in the kit's `.claude/` and are governed by the propagation table, not this one.

### Mandate: every new kit item requires a conscious dogfood decision

When ANY new command, skill, hook, or rule is added to `_claude-project/`, you MUST make and record an explicit dogfood decision in the same change — no silent additions:

- **Dogfooded** → mirror it into the kit's `.claude/` and commit both surfaces.
- **Template-only** → add a row to the table above with the reason, and do NOT mirror it.

"I forgot to decide" is the failure mode this prevents. The decision is part of the addition, not a follow-up.

## Kit is a baseline sync, not compliance enforcement

`/sync-dev-kit` offers diffs for the user to accept, reject, or merge. Consumer projects can consciously diverge:

- Project-specific rules in `<project>/.claude/rules/project/` (never touched by sync)
- Project-specific skills in `<project>/.claude/skills/<custom-name>/`
- Project-specific commands in `<project>/.claude/commands/`
- Custom hooks beyond what the kit provides

The kit maintains a BASELINE across projects. Divergence is expected where it makes sense.

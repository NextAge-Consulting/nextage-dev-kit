# /dev

Stage a dev server in a new iTerm tab. Part of the dev-server subsystem. The canonical and ONLY authorized path for starting dev servers in this project.

## The model

Two problems Agents-view + worktrees created that the old "cmd-t + `cd` + `npm run dev`" flow can't solve:

1. **iTerm cmd-t lands in `~/projects`, not the worktree.** Agents view spawns the host shell from `~/projects` with no project context. `EnterWorktree` changes only Claude's tool-process cwd — iTerm's parent shell never learns about the worktree.
2. **Silent vite port-bump.** Vite's default on port collision is to bump to the next free port (`:3002`, `:3003`) without erroring. Browser-testing `localhost:3001` then tests the wrong project's server.

`/dev` solves both via `osascript`-spawned iTerm tab with explicit `cd` + `lsof` pre-check + structured port-step-by-10 on collision.

## Supported invocations

| Input | What happens |
|-------|--------------|
| `/dev` | List all `dev*` scripts from the resolved project's `package.json`. Await user choice. |
| `/dev <app>` | Stage `npm run dev:<app>` in the current worktree, on the detected port (auto-bumped +10 on collision). |
| `/dev <app1> <app2>` | One iTerm tab per app. |
| `/dev <app> --main` | Stage in the **primary** repo (always on `main`), not the worktree. For side-by-side comparison runs. |
| `/dev <app> --tunnel` | Stage `npm run dev:tunnel:<app>` (cloudflared + vite together). Requires a `dev:tunnel:<app>` script. Mutually exclusive with `--main`. |
| `/dev --status` | List listening processes on `:3000-:3099` (pid, port, cwd, cmd). Never kills. |

## Procedure

### Step 1: Parse arguments

- App names (positional, zero or more).
- `--main` flag → target primary instead of worktree.
- `--tunnel` flag → swap script to `dev:tunnel:<app>` (cloudflared + vite). Mutually exclusive with `--main`.
- `--status` flag → exit after surfacing the listener list.
- Conflicting flags refused.

### Step 2: Invoke the script

```bash
.claude/skills/dev-server/scripts/dev.sh [args...]
```

The script handles project-root detection, port probing, osascript invocation. Surface the script's stdout to the user.

### Step 3: Report

Report each launched tab: app, path, port, command. If the script refused (no free port within 3 hops, no matching `dev:<app>` script, no `package.json`), surface the refusal reason verbatim. Do NOT retry without explicit user direction.

## Port-override mechanic

For each chosen app:

1. **Default port detection.** Reads `port:` from `apps/<app>/vite.config.ts` (monorepo) or `vite.config.ts` (flat). Falls back to `3000` if neither found.
2. **`lsof` probe.** `lsof -iTCP:<port> -sTCP:LISTEN`. If free, use it.
3. **Auto-bump on collision.** Step `+10` each hop. Cap at 3 hops:
   - shop: `3001 → 3011 → 3021`
   - dealer: `3010 → 3020 → 3030`
4. **Refuse beyond 3 hops** — "too many dev servers on this app's slots, stop one first" with the occupant list (pid + cwd) of each occupied slot.
5. **CLI override on launch.** Stages `npm run dev:<app> -- --port <N>`. Vite's CLI `--port` flag overrides whatever's in `vite.config.ts`; no config change is required.

## What the osascript tab does

The new iTerm tab:

- Opens in the current iTerm window (not a new window).
- Runs `cd '<target_dir>'`.
- Sets the tab title via OSC 0 escape (`printf '\e]0;<title>\a'`) to `<app> @ <worktree-name> (:<port>)`. Set AFTER cd so zsh's chpwd-hook title update doesn't overwrite it.
- Runs `npm run dev:<app> -- --port <N>`. The server starts immediately; ctrl-C the tab when done.

`<target_dir>` is:
- The detected worktree root in default mode.
- The detected primary repo root with `--main`.

`<worktree-name>` is the basename of `<target_dir>` — `current`, the compartment name, or the project name for `--main`.

## Blocking conditions

- **No `package.json`** found walking up from cwd → exit 3.
- **No `dev:<app>` script** matching a requested app → exit 4, lists available scripts.
- **No free port within 3 hops** of the default → exit 5, lists occupants of each occupied slot.
- **`osascript` failed** (iTerm not running, or wrong app frontmost) → surface the error; the intended command is printed so the user can run it manually if needed.

## What this command does NOT do

- **Does not start servers without user invocation.** User explicitly types `/dev <app>`; Claude never starts servers on its own.
- **Does not kill servers.** Ever. `--status` is surface-only.
- **Does not start servers in cloud / headless sessions.** No iTerm available.
- **Does not auto-restart on file changes.** The running vite server's job, untouched.

## Edge cases

- **Two Claude sessions, same worktree, both `/dev shop`.** First wins `:3001`, second auto-bumps to `:3011`. Independent tabs.
- **`/dev shop --main` while worktree shop is on `:3001`.** Primary takes `:3011` (auto-bumped). Or stop worktree first, then re-run for primary on `:3001`.
- **`/merge` tears down the worktree but the dev tab is still running.** Vite throws on the next file-watch event against the gone path. Pete sees it, ctrl-C's that tab. Acceptable — better than auto-killing across sessions.
- **Non-vite dev servers (Next.js, Astro, …).** Work as long as the `dev:<app>` script exists in `package.json` and the dev framework respects `-- --port <N>` after `npm run`. Port detection won't find anything in `vite.config.ts` and falls back to `3000`; user can override or add `apps/<app>/vite.config.ts` with the port to make detection work. Future enhancement: project-level `.claude/dev-server.json` map.

## Related

- `.claude/rules/dev-server.md` — the 5 rules of server lifecycle (check first, use occupied, never kill, leave running) that still apply once a server is running.
- `.claude/skills/dev-server/SKILL.md` — natural-language routing layer.
- `.claude/skills/e2e/SKILL.md` — the one path that legitimately auto-starts servers outside `/dev` (unattended verification runs).
- `project-documentation/DEVSERVER-CHEATSHEET.md` — one-page reference.

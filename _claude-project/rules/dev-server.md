# Dev Server Protocol

**Be smart about dev servers — not blocked from them.** The prior version of this rule required user permission for every start. That was a blunt fix for a real behavioral failure (Claude starting servers blindly, stacking ports `:3001`, `:3002`, `:3003`, killing occupied ports to "take" them, starting alternate ports to sidestep an occupied primary). The rule below targets those failure modes directly instead of blocking all server interaction.

## Canonical start path: `/dev`

**The user starts dev servers via `/dev` (the dev-server skill).** `/dev` opens a new iTerm tab in the project root, runs `cd` + the dev command. Port collisions are detected via `lsof` and auto-bumped by `+10` (3001 → 3011 → 3021, capped at 3 hops). Tab title is set via OSC 0 escape to `<app> @ <project-name> (:<port>)`.

Claude does **not** start dev servers without user invocation — `/dev` is user-driven only. See:

- `.claude/skills/dev-server/SKILL.md` — natural-language routing.
- `.claude/commands/dev.md` — slash command spec.
- the kit's `project-documentation/DEVSERVER-CHEATSHEET.md` — one-page reference.

**One exception:** `/e2e` legitimately auto-starts dev servers when no port is occupied (so a verification run can proceed unattended). See `.claude/skills/e2e/SKILL.md`. The 5 rules below still apply to that path.

## The five rules

1. **Always check first.** Before any server action: `lsof -iTCP:<port> -sTCP:LISTEN`. Know what's actually on the port.
2. **If the port is occupied, USE IT.** The occupant is the user or another session — both fine. Never kill it. Never question it. Never start an alternate port (`:3002`, `:3011`, etc.) to sidestep it. The server that's running IS the server under test.
3. **If the port is free and the task requires a server**, you may start it. Announce clearly: `"starting <service> on :<port> for <reason>"`. Direct stdout/stderr to `logs/server.log` (or the project-conventional path). Use the project's standard start command (`npm run dev:<app>`, `npm start`, etc.). Never double-background — don't put `&` inside a `run_in_background` command. It orphans the process and hides it from the status bar. Use one backgrounding mechanism, not both.
4. **Never kill processes you didn't start. This is the most important rule in this file.** 99% of the time a dev server is running, the user is actively testing against it. Killing it mid-stream destroys the user's flow. Applies to `kill`, `kill -9`, `pkill`, `lsof … | xargs kill`, `fuser -k`, and `docker stop` on running containers. If a server is misbehaving, surface it to the user — don't cull it.
5. **Leave the USER's servers running; kill YOUR OWN at handoff.** A server the user started (via `/dev`) or another session's is a shared resource — leave it running; killing it is never your call (rule 4). But a server **you or a subagent** started is **invisible to the user** — no iTerm tab, no way for them to see or stop it. So **when the task is done and you hand back, there must be zero background servers you spawned still running.** A leftover silently occupies a port the user's next `/dev` bumps around, and they can't see why ("why did my server land on :3040?"). Don't thrash a server up/down mid-task — start it once, kill it once at the end. Killing your OWN server is authorized without asking (prefix `SKIP_SERVER_GUARD=1` to pass the guard hook); killing a user/other-session server still needs explicit user authorization.

## Server log monitoring

- Default log path: `logs/server.log` (projects with multiple servers may use per-service paths like `logs/server-dealer.log`)
- Monitor: `tail -f logs/server.log`

## What the old rule was catching (and the new rule still catches)

- **Killing the user's running dev server to start your own** — the cardinal sin. The user is almost always mid-test when a server is running. Killing it mid-stream nukes their session.
- Starting `npm run dev` without checking → stacking duplicate servers.
- Starting `:3002` when `:3001` was occupied → running tests against the wrong server.
- Starting servers for trivial reasons (one-shot curl, port-ping) instead of just reading a file or running a unit test.

If you're about to do any of those, stop. Rule 2 (use an occupied port) + rule 4 (never kill what you didn't start) + rule 5 (leave the user's running, clean up your own at handoff) handle the first three directly. The last one is a judgment call — don't start a server if the task can be done without one.

## Hook enforcement

The `.claude/hooks/dev-server-guard.sh` hook enforces rule 4 at the tool-call layer by blocking `pkill` / `kill` patterns targeting dev servers. Rules 1, 2, 3, 5 are behavioral — enforced by you reading this file, not by the hook.

Emergency override for the hook: `SKIP_SERVER_GUARD=1 <command>`. Two authorized uses: (a) the user explicitly authorized killing a specific process, or (b) you are cleaning up a server **you** (or your subagent) started, at handoff (rule 5). Never use it to kill a user/other-session server without (a).

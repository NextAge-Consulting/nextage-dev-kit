# Dev-Server Cheat Sheet

One-page reference for starting dev servers in a kit-enabled project. Companion to `gitflow-cheatsheet.md`.

The `/dev` skill (`_claude-project/skills/dev-server/`) and slash command (`_claude-project/commands/dev.md`) are the canonical entry point. Universal across projects via kit sync.

---

## One-time install: DevServer iTerm profile (macOS / iTerm2 only)

Skip this if you drive `/dev` through tmux — it applies to the iTerm backend alone.

On the iTerm path, `/dev` spawns each tab using a separate iTerm profile called **DevServer** that has `Allow Title Setting = true`. This is intentional — your regular profile (e.g. CPL) keeps `Allow Title Setting = false` so Claude Code's startup OSC-0 width-probe doesn't corrupt Claude's tab title. The DevServer profile is used ONLY by `/dev` tabs, where vite/etc. run and don't title-probe.

Install once per dev machine:

```bash
mkdir -p "$HOME/Library/Application Support/iTerm2/DynamicProfiles"
cp .claude/skills/dev-server/templates/DevServer.json \
   "$HOME/Library/Application Support/iTerm2/DynamicProfiles/DevServer.json"
```

iTerm hot-loads DynamicProfiles — no iTerm restart needed. `/dev` will fail with a clear error if the profile is missing.

---

## Why this skill exists

Two problems the Agents-view workflow created that the old flow can't solve:

1. **iTerm cmd-t lands in `~/projects`, not the project.** Agents view spawns the host shell from `~/projects` with no project context, so "Reuse previous session's directory" reuses the wrong directory. cmd-t → manual `cd` every time, or land in the wrong place.
2. **Port collision is silent and dangerous.** Many projects bind `:3001`. Vite's default behavior on collision is to **silently bump to the next free port** (`:3002`, `:3003`). You browser-test `localhost:3001` thinking it's your project; it's actually a different project's server. The 100% gitflow-via-skill model exists to make this footgun structurally impossible.

`/dev` is the sole, universal entry point. Mirrors the role gitflow's `/commit` plays for git.

---

## Starting a server

```
/dev                       # list dev* scripts from package.json; prompt which
/dev shop                  # start shop at the project root
/dev shop dealer           # two tabs: shop + dealer
/dev shop --tunnel         # start shop with a Cloudflare named tunnel (cloudflared + vite in one tab)
/dev --status              # surface running dev servers (pid, port, cwd) — never kills
```

What `/dev <app>` does, in order:

1. **Detect cwd** at invocation — walks up to the nearest `package.json` with `dev*` scripts.
2. **Probe the declared port** (from `vite.config.ts` / equivalent): `lsof -iTCP:<port> -sTCP:LISTEN`.
3. **Pick a port:**
   - Free → use the default (e.g. `:3001` for shop, `:3010` for dealer).
   - Occupied → step by +10 (`:3001 → :3011 → :3021`, `:3010 → :3020 → :3030`). Cap at 3 hops; refuse beyond — "too many dev servers, stop one first."
4. **Open a new tab** (see "Where the window lands" below for which terminal):
   - `cwd` = detected project root.
   - Title = `<app> @ <project-name> (:<port>)` — glanceable.
   - Staged command = `<PORT_ENV>=<port> npm run dev:<app>`. An env var is used rather than `-- --port`, which npm's flag parser eats before it reaches vite. `<PORT_ENV>` is whatever the app's `vite.config.ts` reads, defaulting to `PORT`.
   - Server starts immediately. ctrl-C the tab when done.

User-invocation is non-negotiable — Claude only runs `/dev` when the user explicitly types it (`.claude/rules/dev-server.md` rules 1–5).

---

## Where the window lands

`/dev` tries four backends in a fixed order and tells you which one it used, on the `where:` line of its output.

| Order | When | You get |
|---|---|---|
| 1 | `$TMUX` is set — Claude's own shell is **inside tmux** | A tmux window in your current session. `Ctrl-b n` to switch, `Ctrl-b p` to come back. |
| 2 | A tmux client is **attached** to some session | A tmux window in that session, same as 1. Covers the common case where you are sitting in tmux but `$TMUX` did not survive into Claude's environment. |
| 3 | Otherwise, on macOS with iTerm2 | A new iTerm tab in the current window — the original behavior, unchanged. |
| 4 | Otherwise, if tmux is installed and **nobody is attached** | A window in a tmux session named `dev`. The script prints `tmux attach -t dev` to reach it. |
| — | None of the above | A refusal, with the command and path printed so you can run them yourself. |

**If the `where:` line names the `dev` session while you are sitting in tmux, that is now a bug**, not the expected path. Order 4 is only for an unattended tmux server.

**tmux is not a terminal.** It runs inside one — you still open iTerm (or any terminal), then run `tmux` in it, and tmux gives you its own tabs inside that single window, listed along the bottom. On macOS with iTerm this is redundant, which is why order 3 exists and why nothing about the Mac workflow changes. It earns its place on Linux, where terminals generally cannot be asked to open a tab from a script, and it is the only option that works headless or over ssh.

**Order 3 sits below iTerm deliberately.** A running tmux server tells you a server exists somewhere on the machine — not which window you are looking at, or whether you are attached at all. If it outranked iTerm, anyone on macOS who left a tmux server running would quietly stop getting iTerm tabs.

**Linux users: start Claude inside tmux** (`tmux`, then `claude`) to get order 1 and true tab parity with the macOS experience.

---

## Multi-app monorepo (shop + dealer + …)

Each app has its own declared port (shop `:3001`, dealer `:3010`). The +10 step keeps slots separate:

| App | Default | Hop 1 | Hop 2 |
|---|---|---|---|
| shop | 3001 | 3011 | 3021 |
| dealer | 3010 | 3020 | 3030 |
| (future) | 30N0 | 30N0+10 | 30N0+20 |

Run both at once: `/dev shop dealer` (two tabs, two ports).

The +10 pattern leaves room for adjacent apps. No collision between shop's hops (3001/3011/3021) and dealer's defaults (3010/3020/3030) until you're at hop 2+ on both, by which point you have bigger problems.

---

## What `/dev` does NOT do

- **Does not start servers on its own.** Only runs when you explicitly type `/dev <app>`.
- **Does not kill servers.** Ever. `--status` surfaces; you ctrl-C. Mirrors `dev-server.md` rule 4.
- **Does not auto-restart on file changes.** That's vite's job inside the running server.
- **Cloudflare tunnel** is supported via `--tunnel` (see "Tunneling a dev server" below). Without that flag, `/dev` does not touch cloudflared.
- **Does not interfere with vitest.** `vitest` / `npm run test` aren't dev servers, no port binding, completely orthogonal.

---

## Tunneling a dev server (`--tunnel`)

`/dev <app> --tunnel` swaps the staged command to `npm run dev:tunnel:<app>`, which the kit ships at `_claude-project/skills/dev-server/scripts/dev-with-tunnel.mjs`. That script:

1. Builds the public hostname as `<app>.thenextage.com` — this shop's standard tunnel parent domain, hardcoded.
2. Spawns `cloudflared tunnel run` (reads `~/.cloudflared/config.yml`) + `npm run dev:<app>` in the same tab.
3. Propagates the `PORT` chosen by `/dev`'s `lsof` pre-check into vite via env.
4. Injects `BETTER_AUTH_URL` + `VITE_BETTER_AUTH_URL` = `https://<app>.thenextage.com` so better-auth's cookie domain + redirect URLs use the tunnel origin, not `localhost`. Apps without better-auth ignore these.

### One-time per-project setup

**Wire `dev:tunnel:<app>` scripts** in `package.json`, e.g.:

```json
"dev:tunnel:shop":   "node .claude/skills/dev-server/scripts/dev-with-tunnel.mjs shop",
"dev:tunnel:dealer": "node .claude/skills/dev-server/scripts/dev-with-tunnel.mjs dealer"
```

### One-time per-user-machine setup

1. **Cloudflare DNS** (one-time, dashboard): wildcard CNAME `*.thenextage.com` → `<tunnel-uuid>.cfargotunnel.com`, Proxied. Universal SSL covers single-label wildcards natively; no paid Advanced Cert needed.
2. **`~/.cloudflared/config.yml`** — per-app ingress entries:

   ```yaml
   tunnel: <tunnel-uuid>
   credentials-file: /Users/<you>/.cloudflared/<tunnel-uuid>.json

   ingress:
     - hostname: shop.thenextage.com
       service: http://localhost:3001
     - hostname: dealer.thenextage.com
       service: http://localhost:3010
     - service: http_status:404
   ```
3. **Each app's `vite.config.ts`** — add the public hostname to `server.allowedHosts`:

   ```ts
   allowedHosts: ['.trycloudflare.com', 'shop.thenextage.com'],
   ```

### Costs

Each `/dev <app> --tunnel` invocation spawns its own `cloudflared` process. Cloudflare treats them as tunnel replicas of the same UUID — they share the ingress map, traffic load-balances across replicas, no contention. Real cost: ~30–50MB RAM and a handful of edge keepalive connections per replica. Trivial. Running `/dev shop --tunnel` + `/dev dealer --tunnel` simultaneously = two cloudflared processes serving both hostnames; works without intervention.

### What `--tunnel` does NOT support

## E2E interaction

`/e2e` (per `.claude/skills/e2e/SKILL.md`) auto-starts dev servers when no port is occupied — required so a verification run can proceed unattended. This is **the one path** that legitimately starts a server outside `/dev`.

- E2E checks the port, uses it if occupied (rule 2), starts if free (logged to `logs/server.log`).
- E2E does NOT kill servers it didn't start (rule 4).
- No hook blocks this — `/dev` is canonical-by-convention (mirrors `agent-browser`), not enforced by a guard. Reasoning: every bypass token weakens the structural claim, and the easy-path argument carries it.

---

## Universal across projects

Lives in `_claude-project/skills/dev-server/` in this kit → synced to every consumer project via `/sync-dev-kit`. Same skill works for:

- Monorepos with multiple workspace apps (`dev:shop`, `dev:dealer`, …).
- Flat repos with a single `dev` script (`/dev` prompts → runs the one option).
- Any project that follows the `dev*` script convention in root `package.json`.

No per-project zshrc functions. No project-specific shell aliases. The kit is the source of truth.

---

## What NOT to do

- **Raw `npm run dev` in a terminal.** Silent port-bump = testing the wrong server. Use `/dev`.
- **Manually killing another session's dev server.** `dev-server.md` rule 4. If a port is occupied, the occupant is you or another session — either is fine. Use it (rule 2) or run via `--main` / port-override.
- **Asking Claude to "start the dev server for me."** Claude doesn't initiate. You explicitly type `/dev <app>` — same explicit-user-intent model as `/commit`.
- **Starting servers on alternate ports to sidestep a collision.** Use the structured port override via the skill; don't pick a random port.

---

## Troubleshooting quickies

| Symptom | Fix |
|---------|-----|
| Tab title shows cwd instead of `<app> @ <project> (:<port>)` | The DevServer iTerm profile isn't installed — `/dev` falls back to the default profile which has `Allow Title Setting = false`. Run the one-time install at the top of this file. Verify with `ls "$HOME/Library/Application Support/iTerm2/DynamicProfiles/DevServer.json"`. iTerm hot-loads; no restart. |
| `/dev` errors "couldn't find profile DevServer" | Same fix — install the DynamicProfile. |
| New iTerm tab landed in `~/projects` not the project | Confirms the Agents-view-cwd gap. Use `/dev` — it passes the right path explicitly. Don't try to fix it in iTerm settings. |
| Window opened in tmux when you expected an iTerm tab | You started Claude inside tmux, so tmux outranks iTerm — that window is the tab next to you (`Ctrl-b n`). Start Claude outside tmux for iTerm tabs. |
| `/dev` says it opened a window but you can't see it | It landed in the `dev` tmux session. `tmux attach -t dev`. That path is only taken when iTerm2 was unreachable. |
| `/dev` refuses with "no terminal available to open a tab in" | The session has no backend: not inside tmux, no iTerm2, no tmux installed. Install tmux and start Claude inside it, or run the printed command by hand. |
| Browser test against `localhost:3001` is showing the wrong project | Almost certainly silent vite port-bump. `lsof -iTCP:3001 -sTCP:LISTEN` to see what's actually on :3001. Use `/dev --status` once the skill ships. |
| `/dev` refuses — "too many dev servers (3 hops exhausted)" | You have 3+ servers fighting for slots in the same app's range. Stop one (`/dev --status` to identify, ctrl-C the tab you're done with). |
| Need a server on a specific port for a one-off | `/dev shop --port 3099` (future flag — TBD if needed in practice). |
| Two Claude sessions both want to run shop | First wins :3001. Second auto-bumps to :3011. Third to :3021. Fourth is refused. |

---

## Cross-references

- `.claude/rules/dev-server.md` — the 5 rules (always check, use occupied port, never kill, etc.) that still govern lifecycle regardless of how the server was started.
- `.claude/skills/e2e/SKILL.md` — the one legitimate path that auto-starts servers outside `/dev`.
- `.claude/skills/agent-browser/SKILL.md` — the precedent for skill-as-canonical-by-convention without a guard hook.
- `gitflow-cheatsheet.md` — same shape, same model, for git ops.

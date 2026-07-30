# Dev-Server Cheat Sheet

One-page reference for starting dev servers in a kit-enabled project. Companion to `GITFLOW-CHEATSHEET.md`.

The `/dev` skill (`_claude-project/skills/dev-server/`) and slash command (`_claude-project/commands/dev.md`) are the canonical entry point. Universal across projects via kit sync.

---

## One-time install: DevServer iTerm profile

`/dev` spawns each tab using a separate iTerm profile called **DevServer** that has `Allow Title Setting = true`. This is intentional — your regular profile (e.g. CPL) keeps `Allow Title Setting = false` so Claude Code's startup OSC-0 width-probe doesn't corrupt Claude's tab title. The DevServer profile is used ONLY by `/dev` tabs, where vite/etc. run and don't title-probe.

Install once per dev machine:

```bash
mkdir -p "$HOME/Library/Application Support/iTerm2/DynamicProfiles"
cp .claude/skills/dev-server/templates/DevServer.json \
   "$HOME/Library/Application Support/iTerm2/DynamicProfiles/DevServer.json"
```

iTerm hot-loads DynamicProfiles — no iTerm restart needed. `/dev` will fail with a clear error if the profile is missing.

---

## Why this skill exists

Two problems Agents-view + worktrees created that the old workflow can't solve:

1. **iTerm cmd-t lands in `~/projects`, not the worktree.** Agents view spawns the host shell from `~/projects` with no project context. `EnterWorktree` changes only Claude's tool-process cwd — iTerm's parent shell never learns about the worktree, so "Reuse previous session's directory" reuses the wrong directory. cmd-t → manual `cd` every time, or land in the wrong place.
2. **Port collision is silent and dangerous.** Many projects bind `:3001`. Vite's default behavior on collision is to **silently bump to the next free port** (`:3002`, `:3003`). You browser-test `localhost:3001` thinking it's your worktree; it's actually a different project's server. The 100% gitflow-via-skill model exists to make this footgun structurally impossible.

`/dev` is the sole, universal entry point. Mirrors the role gitflow's `/commit` plays for git.

---

## Starting a server

```
/dev                       # list dev* scripts from package.json; prompt which
/dev shop                  # start shop in the current worktree
/dev shop dealer           # two tabs: shop + dealer
/dev shop --main           # start shop in the PRIMARY repo (main), not the worktree
/dev shop --tunnel         # start shop with a Cloudflare named tunnel (cloudflared + vite in one tab)
/dev --status              # surface running dev servers (pid, port, cwd) — never kills
```

What `/dev <app>` does, in order:

1. **Detect cwd** at invocation — walks up to the nearest `package.json` with `dev*` scripts. Defaults to the worktree the Claude session is in.
2. **Probe the declared port** (from `vite.config.ts` / equivalent): `lsof -iTCP:<port> -sTCP:LISTEN`.
3. **Pick a port:**
   - Free → use the default (e.g. `:3001` for shop, `:3010` for dealer).
   - Occupied → step by +10 (`:3001 → :3011 → :3021`, `:3010 → :3020 → :3030`). Cap at 3 hops; refuse beyond — "too many dev servers, stop one first."
4. **Open a new iTerm tab via `osascript`:**
   - `cwd` = detected worktree (or primary, if `--main`).
   - Title = `<app> @ <worktree-name> (:<port>)` — glanceable.
   - Staged command = `npm run dev:<app> -- --port <port>` (vite CLI `--port` overrides the config; no vite.config change required).
   - Server starts immediately. ctrl-C the tab when done.

User-invocation is non-negotiable — Claude only runs `/dev` when the user explicitly types it (`.claude/rules/dev-server.md` rules 1–5).

---

## Running main vs worktree side-by-side

The 95% case is one server in one worktree. The visual-comparison / regression-check case wants both:

```
/dev shop --main           # tab opens in ~/projects/<project>/ on :3001
/dev shop                  # from a worktree session — detects :3001 taken, runs on :3011
```

Browser:
- `localhost:3001` → main (primary repo, untouched)
- `localhost:3011` → worktree (whatever branch `current/` is on)

Both tabs are independent. ctrl-C whichever you're done with. No cross-tab coupling.

**Caveat.** When `/merge` tears down the worktree, the worktree tab keeps running against a now-gone path. Vite will throw on the next file-watch event. You'll see it. ctrl-C that tab. Acceptable — better than auto-killing across sessions.

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

**Combined with `--main`.** Tunnel ingress targets the worktree-side `PORT`; `--main` runs in the primary repo on a different port and a different cwd. The script refuses the combo.

---

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

- **Raw `npm run dev` in iTerm.** Silent port-bump = testing the wrong server. Use `/dev`.
- **Manually killing another session's dev server.** `dev-server.md` rule 4. If a port is occupied, the occupant is you or another session — either is fine. Use it (rule 2) or run via `--main` / port-override.
- **Asking Claude to "start the dev server for me."** Claude doesn't initiate. You explicitly type `/dev <app>` — same explicit-user-intent model as `/commit`.
- **Starting servers on alternate ports to sidestep a collision.** Use the structured `--port` override via the skill; don't pick a random port.

---

## Troubleshooting quickies

| Symptom | Fix |
|---------|-----|
| Tab title shows cwd instead of `<app> @ <worktree> (:<port>)` | The DevServer iTerm profile isn't installed — `/dev` falls back to the default profile which has `Allow Title Setting = false`. Run the one-time install at the top of this file. Verify with `ls "$HOME/Library/Application Support/iTerm2/DynamicProfiles/DevServer.json"`. iTerm hot-loads; no restart. |
| `/dev` errors "couldn't find profile DevServer" | Same fix — install the DynamicProfile. |
| New iTerm tab landed in `~/projects` not the worktree | Confirms the Agents-view-cwd gap. Use `/dev` — it osascripts the right path explicitly. Don't try to fix it in iTerm settings. |
| Browser test against `localhost:3001` is showing the wrong project | Almost certainly silent vite port-bump. `lsof -iTCP:3001 -sTCP:LISTEN` to see what's actually on :3001. Use `/dev --status` once the skill ships. |
| `/dev` refuses — "too many dev servers (3 hops exhausted)" | You have 3+ servers fighting for slots in the same app's range. Stop one (`/dev --status` to identify, ctrl-C the tab you're done with). |
| Worktree tab is erroring after `/merge` torn down `current/` | Expected. ctrl-C the tab. The server is running against a path that no longer exists. |
| Need a server on a specific port for a one-off | `/dev shop --port 3099` (future flag — TBD if needed in practice). |
| Two Claude sessions both want to run shop in different worktrees | First wins :3001. Second auto-bumps to :3011. Third to :3021. Fourth is refused. |

---

## Cross-references

- `.claude/rules/dev-server.md` — the 5 rules (always check, use occupied port, never kill, etc.) that still govern lifecycle regardless of how the server was started.
- `.claude/skills/e2e/SKILL.md` — the one legitimate path that auto-starts servers outside `/dev`.
- `.claude/skills/agent-browser/SKILL.md` — the precedent for skill-as-canonical-by-convention without a guard hook.
- `GITFLOW-CHEATSHEET.md` — same shape, same model, for git ops.

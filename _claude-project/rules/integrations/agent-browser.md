### Browser Testing with agent-browser

**Policy:**
- ALWAYS test and iterate until you have a correct result
- Use email/password login only — Google OAuth is blocked by Playwright bot detection
- Check `.env` for test credentials before asking the user

**Startup Sequence (always use this):**
```bash
agent-browser --headed open http://localhost:3001
agent-browser set viewport 1440 900
agent-browser wait --load networkidle
agent-browser snapshot -i
```
- `--headed` is required so the user can see the browser
- **Viewport = 1440×900.** Fits every mainstream laptop screen (MacBook 14" builtin ≈ 1512×982, MBA 13" = 1440×900) plus every external monitor. Stays above typical responsive breakpoints (768/1024) so desktop UI renders as designed. 1920×1080 is desktop-ideal but excludes laptop-developer workflows. Playwright defaults to 1280×720 with no explicit call.
- **Manual resize caveat.** If you manually resize the browser window via the OS, Playwright's virtual viewport does NOT follow — this is an upstream limitation in both agent-browser (#592) and Playwright (#14091). Re-run `agent-browser set viewport 1440 900` to resync, or just don't resize manually.
- Dev server: typically `http://localhost:3001`. Server lifecycle (when to start, never kill, leave running) is governed by `.claude/rules/dev-server.md`.
- Always `snapshot -i` after navigation or DOM changes to get fresh refs

**Teardown — ALWAYS `agent-browser close` when done.**
agent-browser keeps a persistent background daemon holding the browser open (via CDP) so commands stay fast. It does NOT close on its own: the Chrome-for-Testing window lingers and can only be force-quit — which makes macOS auto-updates fail. So the moment a browser task finishes — a single flow, a whole suite, or an ad-hoc check, pass or fail — run `agent-browser close`. Chain it so it always fires even mid-routine: `<last command> && agent-browser close`. Fallbacks if the daemon is wedged and `close` won't take: `pkill -f agent-browser` (kills the daemon), then `find ~/.agent-browser -maxdepth 1 -type s -delete` (clears stale sockets left by an interrupted run). This is the one lifecycle exception to "leave things running" — the browser is Claude's tool, not a shared resource. (Dev servers still stay up per `.claude/rules/dev-server.md`.)

**Cross-origin iframes (Stripe, reCAPTCHA, etc.):**
`agent-browser find` does NOT traverse cross-origin iframes (upstream gap — [agent-browser#279](https://github.com/vercel-labs/agent-browser/issues/279)). Playwright's `frameLocator` would solve this but agent-browser doesn't expose it. Workaround for Stripe PaymentElement:

1. Find the iframe's bounding rect via `agent-browser eval` at runtime (position depends on page layout)
2. Click at `(rect.x + iframe_relative_x, rect.y + iframe_relative_y)` using `mouse move` + `mouse down` + `mouse up`. **Internal offsets are viewport-independent** because Stripe uses fixed-pixel row heights, so the same `+50, +105` works on any monitor / viewport size.
3. Use `keyboard type` to send keystrokes — Stripe auto-advances between card/expiry/CVC/ZIP fields
4. Do NOT adjust the X offset based on viewport — X is iframe-relative. Only Y may need tuning if Stripe redesigns row heights.

**Debugging:**
- Check console after interactions: `agent-browser eval 'JSON.stringify(console)' ` or use snapshot to verify state
- Take screenshots when visual verification is needed
- Check network failures with eval if API calls seem broken

**Auth:**
- Login via email/password form fields
- Google OAuth will not work — don't attempt it
- If login state is needed across commands, use `agent-browser state save/load`

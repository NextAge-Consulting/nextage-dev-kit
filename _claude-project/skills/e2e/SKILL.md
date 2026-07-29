---
name: e2e
description: Run Claude-as-intelligent-tester E2E verification via agent-browser. Discovers flow files from `apps/shared/test/e2e/*.md` (monorepo shared layout) or `test/e2e/*.md` (flat layout). Invoke when the user explicitly types `/e2e` with an optional flow name. Triggers: "run e2e", "e2e the homepage", "verify the checkout flow".
allowed-tools: Bash(agent-browser:*), Bash(npx agent-browser:*), Bash(lsof:*), Bash(git diff:*), Bash(git status:*), Bash(cat:*), Read, Glob, Grep
---

# /e2e — Claude-as-intelligent-tester

## What this is

The E2E testing model for this shop is locked (kit `PIPELINE.md` §1.5; memory `feedback_e2e_model_locked.md`). **No Playwright. No Stagehand. No scripted test suite.** Claude drives `agent-browser` through plain-English flow files; failure is detected behaviorally. This skill is the entry point.

## Invocation modes

| Mode | Trigger | Behavior |
|---|---|---|
| Forced all-flows | user types `/e2e all` | Run every discovered flow regardless of diff. No scope question. |
| Single-flow | user types `/e2e <flow-name>` | Run only the flow whose `name:` frontmatter matches. No scope question, no diff check. |
| Scope question | user types `/e2e` (no arg) | Ask the shared scope question (below) and run whatever the user picks. |

This skill is invoked by the user. It is **not** an auto-firing gate — it runs only when the user asks for it.

## The scope question

When invoked with no flow-name arg, ask **one** `AskUserQuestion`: **"Which E2E flows?"**

| Option | Behavior |
|---|---|
| **Diff-scoped** (default) | Run every flow whose `triggers:` match the current diff. This is where the diff logic fires. If the diff matches zero flows: report "no E2E coverage needed for this diff" and exit 0. |
| **All flows** | Run every discovered flow. |
| **Select specific…** | Ask a **second** `AskUserQuestion` with `multiSelect: true` listing every discovered flow's `name:`. Run exactly the checked flows. |

The diff-scoped path's resolution: `git diff --name-only main..HEAD` (or against the PR base if different), intersect changed files with each flow's `triggers:`. On main / no PR with diff-scoped chosen: treat as all flows.

## Flow file discovery

Priority order (first hit wins):

1. `apps/shared/test/e2e/*.md` — monorepo-with-shared layout
2. `test/e2e/*.md` — flat single-package layout

Use `Glob` to list. Each flow file is a markdown doc with YAML frontmatter + human-readable steps.

## Flow file format

```markdown
---
name: shop-homepage
app: shop
port: 3001
requires-auth: false
triggers:
  - "apps/shop/src/routes/**"
  - "apps/shared/**"
---
# Shop homepage loads and renders

## Preconditions
- Shop dev server running on :3001 (see `.claude/rules/dev-server.md`)

## Steps
1. Navigate to `http://localhost:3001`
2. Wait `networkidle`
3. Snapshot with `-i`
4. Confirm header visible (phone number present)
5. Confirm product grid renders
6. Confirm footer visible

## Failure indicators
- Blank page, console errors, missing header/footer, elements agent-browser can't find
```

Frontmatter keys:
- `name` (required) — stable slug used when user invokes `/e2e <name>`
- `app` (required) — short label for log / report output
- `port` (required) — port the flow expects on `localhost`
- `requires-auth` (required, bool) — if true, skill loads `TEST_DEALER_EMAIL` / `TEST_DEALER_PASSWORD` from `.env` before running
- `triggers` (required, list of glob patterns) — if any matches the PR's changed files, this flow is in-scope for the current run

## Procedure

### Step 1: Determine scope

- Invoked with a flow name arg (`/e2e <name>`): jump to step 3 with that single flow.
- Invoked as `/e2e all`: scope = all flows (forced), no question — jump to step 2.
- Otherwise: ask **the scope question** (above). The user's pick yields the in-scope flow set:
  - Diff-scoped → `git diff --name-only main..HEAD` (or against the current PR base if different), intersect with each flow's `triggers:`. Empty set → report "no E2E coverage needed for this diff" and exit 0.
  - All flows → every discovered flow.
  - Select specific → exactly the flows checked in the multiselect follow-up.

### Step 2: Check dev server state

Per `.claude/rules/dev-server.md`:

1. `lsof -iTCP:<port> -sTCP:LISTEN` for every port the in-scope flow set needs.
2. If a port is occupied: that IS the server under test. Proceed.
3. If a port is free: announce intent, start the server (`npm run dev:shop` / `npm run dev:dealer` / project-conventional command), direct output to `logs/server.log` (or `logs/server-<app>.log` for multi-app projects), wait for the server's readiness log line, continue.
4. Never kill a port you didn't start. Leave any server you started running after the flow completes.

### Step 3: Run each flow

For each flow file:

1. `Read` the flow file.
2. Parse frontmatter (`app`, `port`, `requires-auth`, steps).
3. If `requires-auth: true`: grep `.env` for `TEST_<APP>_EMAIL` / `TEST_<APP>_PASSWORD` — abort flow with a loud error if missing (don't silently skip).
4. Execute the agent-browser startup sequence (see `.claude/rules/integrations/agent-browser.md`):
   ```
   agent-browser --headed open http://localhost:<port>
   agent-browser set viewport 1440 900
   agent-browser wait --load networkidle
   agent-browser snapshot -i
   ```
5. Work through the flow's numbered steps in order. After any navigation or DOM change: `snapshot -i` to refresh refs.
6. For each step: report ✅ if expected content visible + interactive, ❌ with a one-line observation if not. **Screenshot every page-changing step** (navigate, submit, modal) to `logs/e2e/<flow-name>/NN-<label>.png` — these are the report's evidence (Step 4).
7. **Click reported success but nothing changed?** The button is below the fold — Playwright doesn't auto-scroll at 1440×900. Use the scroll-then-click recipe (`/e2e-author` R1). This is the single most common false-failure — try it before recording a ❌.
8. On ❌: STOP this flow, continue to the next flow (don't abort the whole run — the user wants the full picture).

### Step 4: Report — HTML with screenshots

Produce a **self-contained HTML report** so the user can fire off a run, come back later, and review with confidence. The screenshots are the trust anchor — the user sees the actual pixels behind every ✅, not just your word.

**Use the shared generator — do NOT hand-roll the HTML/CSS each run.** The template, theme, and lightbox live in `.claude/lib/gen-report.mjs` (a shared kit tool — the analysis skill uses it too; learned once, not re-derived). You supply only the data: write the run to `logs/e2e/results.json`, then run it:
```bash
node "$CLAUDE_PROJECT_DIR"/.claude/lib/gen-report.mjs . logs/e2e/results.json   # → logs/e2e/report.html
```
The `results.json` shape (title, subtitle, note, extraStats, flows[] with steps + shots) is documented in the script header. `shots` paths are relative to `logs/e2e/`. Then hand `logs/e2e/report.html` to the user with SendUserFile. The generator guarantees everything below — this list is the contract it fulfils, not a manual checklist:

- **One file, fully self-contained.** Inline every screenshot as a base64 `data:` URI — no external links to break when the file is opened later.
- **Screenshots open in a true lightbox.** Click a thumbnail to view full-size; the overlay has a visible **✕ close** (top-right), **‹ ›** prev/next arrows that walk every screenshot in the report (wrap-around), and an **"N / total" counter**; the dark backdrop also closes. Pure CSS `:target` only (no JS — it must render in the side panel), one `<img>` per shot (no data duplication). Wire prev/next by giving each shot a global index and pointing the arrows at the neighbouring shot's id (`#shot{i±1}`, modulo the count).
- **Capture wall-clock runtime.** `date +%s` at each flow's start and end; sum for the suite total. Runtimes set the expectation for future runs — always record them, pass or fail.
- **Top: run summary** — timestamp, scope (which flows ran + why), pass/fail tally ("6 flows: 5 ✅, 1 ❌"), and **total suite runtime** (e.g. "24m 30s").
- **Per flow: a section** — flow name, overall ✅/❌, and **duration** (e.g. "4m 12s"), then one row per step: step text, ✅/❌, your one-line observation, and that step's screenshot.
- **Screenshot every page-changing step** (captured in Step 3.6) — enough that the user can eyeball "the cart really had 2 items" behind each pass.
- **Failures stand out** — red row, the observation, and the screenshot at the point of failure.
- Theme-aware, responsive, wide tables scroll inside their own container (never the page body). Plain and scannable — no video, no pixel-diffing, no baselines.

Also emit the compact summary table in your chat reply so the result is legible without opening the file:

```
| Flow | Result | Time | Notes |
|---|---|---|---|
| shop-happy-path | ✅ | 4m 12s | |
| shop-cart | ❌ | 1m 03s | Step 3: add-to-cart below fold, click didn't fire |
| dealer-login | ⏭ | — | Skipped — not in triggered scope |
```

**Honest limit:** screenshots make PASS calls *auditable*, not infallible — a false pass is possible if the page looks right but a subtle bug hides. The report exists so the user can catch that on review. That is the trust model; there is no assertion oracle.

A red flow is the signal to stop and fix before you ship. `/e2e` reports pass/fail; it does not block any merge on its own — acting on a failure is your call.

### Step 5: Close the browser

**Always `agent-browser close` when the run finishes — pass, fail, or partial.** The agent-browser daemon holds Chrome-for-Testing open between commands; if you don't close it the window lingers and can only be force-quit, which breaks the user's macOS auto-updates (see `.claude/rules/integrations/agent-browser.md` → Teardown). Chain it so it fires even if a flow throws. Leave the dev servers running (per `dev-server.md`) — only the browser gets closed.

## Failure semantics

You're not writing `expect(...)`. You're being a user. Failures include:
- Blank page (white screen, no content)
- Click does nothing — button missing, JS crashed, route broken
- Navigation 404s unexpectedly
- Form submit errors out visibly
- Content looks mangled (broken layout, missing images, console errors visible)
- agent-browser can't find the element you expected

When a failure surfaces and you want concrete state: `agent-browser eval 'JSON.stringify({visibility: getComputedStyle(document.body).visibility, errors: window.onerror})'`. Only formalize a step into a structured `agent-browser eval` check if a specific failure class KEEPS slipping through — accretion on demand, not preemptively.

## When a flow fails

- Real bug → fix the bug
- Flow-definition drift (UI changed legitimately, flow file is stale) → update the flow file as part of the same PR
- Either way, don't bypass a red flow. Address it before you ship.

## References

- `.claude/rules/dev-server.md` — server lifecycle
- `.claude/rules/integrations/agent-browser.md` — agent-browser startup conventions
- kit `PIPELINE.md` §1.5 — why this model (no Playwright / no scripted suite)
- Memory `feedback_e2e_model_locked.md` — locked-decision context

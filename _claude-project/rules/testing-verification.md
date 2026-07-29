# Testing & Verification

Who runs tests depends on whether a human is available to hand off to — not how
the session was launched (a background job with a human watching is still
interactive).

## Interactive sessions — the human drives testing

- Do NOT run agent-browser, e2e flows, or any manual verification pass unless the
  human explicitly asks ("test this", "verify it"). Announcing that you're about
  to verify is NOT permission — wait for the ask.
- Your job ends at build + static verification (typecheck, lint, build). Then
  hand off: state what's ready and exactly what a verification would need, and
  let the human run it.
- The human starting a dev server is not an invitation to test against it.

## Autonomous sessions — the AI must self-verify

- A session is autonomous when there's no human to hand off to: a cron /
  scheduled run, OR the human has signaled they're stepping away and delegated
  the work ("execute this plan, I'm out for the night, have it done when I get
  back"). Then the AI MUST verify its own work — drive agent-browser and the
  relevant e2e flows to completion. The interactive restriction does not apply;
  there's no one to defer to.

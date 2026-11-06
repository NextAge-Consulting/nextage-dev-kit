---
description: Hand-run audit of the whole User Experience System, one layer at a time from the bottom up — tokens, components, recipes and rules, screens — asking the judge's questions over everything, never a CI gate.
argument-hint: "[system | tokens | components | references | screens [path] | design <name or url>]"
---

# /design-audit

$ARGUMENTS

Run only when the human asks for it. The commit-time judge asks its questions of what a
change touches; this audit asks them of everything, for a project whose owner has made
time to bring an existing system or existing code into line.

**The questions are `.claude/skills/design-system/references/judge-questions.md`.** The
locator finds every candidate in a layer and the judge answers one question per candidate:

```bash
node .claude/skills/design-system/scripts/locate.mjs --all --layer <layer> > candidates.jsonl
node .claude/skills/design-system/scripts/judge.mjs --candidates candidates.jsonl
```

The mechanical checks run first: `npm run lint:tokens` passes, and
`node .claude/skills/ui-patterns/scripts/check-ui-status.mjs` reports no problems. Pending
items it lists are no bar; the audit adds to them.

## The passes

Run them in this order. With no argument, run every pass from `tokens`; `system` runs
`tokens`, `components` and `references`; a named pass runs alone.

| Pass | Layer audited | Questions asked |
|---|---|---|
| `tokens` | the token, type and styles files the `DESIGN_*` keys name | ROLE-NAME, DUPLICATE-ROLE |
| `components` | every component the inventory lists | TOKEN-AGAINST-PURPOSE, VARIANT-INCOMPLETE, NAMED-FOR-DATA, DUPLICATE-BLOCK over every pair of the same or neighbouring type |
| `references` | every recipe and behaviour rule | TOKEN-AGAINST-PURPOSE, RULE-REACH, RULE-CONFLICT over every pair sharing a surface and an app |
| `screens` | every screen file the UI source holds that is not a component — or only those under `[path]` | TOKEN-AGAINST-PURPOSE, FOLLOWS-RULE, REPAINT, SCREEN-BOX |
| `design` | a Claude Design design's pages, read through the Artifact tool; the session writes the candidates itself — each page against every rule that governs its page type (FOLLOWS-RULE, the page's markup as `screen`), each `class-name` on a mounted component (REPAINT), each plain element drawing a box (SCREEN-BOX) — as JSON lines for `judge.mjs --candidates` | the `screens` questions |

**Settle a pass before starting the next.** A yes left open in a lower layer makes every
layer above it unreliable.

## Settling a yes

Each yes goes to the human one at a time, by `asking-questions.md`: what it costs, what it
risks, what it buys, and what carrying it would mean. Never a recommendation on how
anything should look. Each answer lands in the same pass:

- **Fix the work** — the token, component, reference or screen is brought into line with
  the layers beneath it.
- **Add to the system** — the layer beneath gains what was missing, pending, and
  everything it reaches is brought into line.
- **Approve it as it is** — `design-accepted — <the human's reason>` on the line: `/* … */`
  in CSS, `{/* … */}` in JSX, `<!-- … -->` in Markdown. No later audit or judge raises it.
  Arrangement only: a behaviour that departs from its rule is fixed, or the rule is
  changed for every screen — behaviour never differs by exception.
- **Defer it** — `design-deferred <fingerprint>` on the line
  (`check-ui-status.mjs --line-fingerprint <file> <n>`), or `ui-status: deferred` with the
  file's fingerprint on its inventory line. It blocks nothing and comes back when the code
  changes.

Nothing changes without the human's answer. They may stop part-way; what is settled stays
settled.

## Report

How many candidates each pass judged, each yes with its outcome, and anything left for the
human.

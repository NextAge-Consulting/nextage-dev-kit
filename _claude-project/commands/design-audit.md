---
description: Hand-run audit of the whole design, one layer at a time from the bottom up — tokens, parts, patterns, screens — against the same design checks the commit review applies to each change. Never a CI gate.
argument-hint: "[system | tokens | parts | patterns | screens [path] | design <name or url>]"
---

# /design-audit

$ARGUMENTS

Run only when the human asks for it. The commit design review applies the same checks to
every change as it lands; this audit applies them to everything, for a project whose owner
has made time to bring an existing system or existing code into line.

**The checks are `.claude/skills/design-system/references/design-checks.md`, every one of
them, including those marked *Whole layer*.** Each pass applies that layer's section.

## The passes

Run them in this order. With no argument, run every pass from `tokens`; `system` runs
`tokens`, `parts` and `patterns`; a named pass runs alone.

| Pass | Layer audited | Material beneath it |
|---|---|---|
| `tokens` | `design.md`, and the token, type and styles files that `DESIGN_UI_PACKAGE`, `DESIGN_TOKEN_FILES`, `DESIGN_TYPE_FILE` and `DESIGN_STYLES_FILE` in `.claude/sync-substitutions.json` name | `.claude/skills/design-system/references/design-opinion.md` |
| `parts` | `.claude/rules/project/ui-inventory.md`, and the source of every part it lists | the `tokens` layer, its purposes (`node .claude/skills/design-system/scripts/check-design-tokens.mjs --purposes`), and `references/block-types.md` |
| `patterns` | every reference in `.claude/skills/ui-patterns/references/` | the `parts` material, and the `parts` layer |
| `screens` | every UI source file in the folders `node .claude/skills/design-system/scripts/ui-sources.mjs` prints that is not a part — or only those under `[path]` | the `patterns` material, and the `patterns` layer |
| `design` | a Claude Design design's pages, read through the Artifact tool, judged as the `screens` layer | the `patterns` material, and the `patterns` layer |

**Each pass runs in a fresh agent** (the Agent tool, `general-purpose`) given only
`design-checks.md`, its layer and the material beneath it — never this conversation. It
reads every file it is given, states how many it inspected, and reports each finding under
its check's name.

**Settle a pass before starting the next.** A finding left open in a lower layer makes every
layer above it unreliable; take the open ones to the human first.

## Settling the findings

Take each finding to the human one at a time, by `asking-questions.md`: what it costs,
what it risks, what it buys, and your recommendation. Each answer lands in the same pass:
- **A change to the layer's own file** — a token, a part, a pattern rule or a screen fixed
  with what the layers beneath it already hold.
- **A change beneath it** — the token, part or pattern that should answer the question
  gains it, and everything that layer reaches is brought into line in the same pass.
- **Accepted** — a comment on the line, `design-accepted — <the human's reason>`, or
  `design-accepted(<reference file>) — <reason>` for a departure from one pattern:
  `/* … */` in CSS, `{/* … */}` in JSX, `<!-- … -->` in Markdown. Every later audit and
  review skips it.

A **worth a look** item goes to the human as a question, never as a violation: adopt the
guideline, or keep their own value. Keeping it needs no reason — the line is marked
`design-choice`, and nothing lists it again.

## Report

How many files each pass inspected, each finding with its outcome, and anything left for
the human.

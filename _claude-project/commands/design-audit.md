---
description: Hand-run audit of the project's design system against the kit's design opinions, then of its UI code or a design against that system. Never a CI gate.
argument-hint: "[system | project [path] | design <name or url>]"
---

# /design-audit

$ARGUMENTS

Run only when the human asks for it. New work is already held to the system by the
changed-lines checks; this audit is for a project whose owner has made time to bring
existing code or an existing system into line.

**Each pass runs in a fresh agent** (the Agent tool, `general-purpose`) given only the
material the pass names — never this conversation. It reads every file it is given and
states how many it inspected.

## Pass 1 — `system`: the design system against the kit's opinions

Material:
- `design.md`;
- the token, type and styles files named by `DESIGN_UI_PACKAGE`, `DESIGN_TOKEN_FILES`,
  `DESIGN_TYPE_FILE` and `DESIGN_STYLES_FILE` in `.claude/sync-substitutions.json`;
- `.claude/rules/project/ui-inventory.md`, and the source of every part it lists;
- `.claude/skills/design-system/references/block-types.md` and `design-opinion.md`.

The agent reports only:
- **Incomplete** — the system is silent where `design-opinion.md` has an opinion. Recommend
  adopting it, in the project's own token and part names.
- **Breaks an absolute with no reason recorded** — a side marked *(the kit's side)*, or a
  floor the file sets: contrast, target size, focus that can be seen. Adopt it, or record
  the project's reason where the system holds the value.
- **Inconsistent with itself** — a role named by size; two roles doing one job; a token with
  no comment saying what it is for; a value off the system's own scale. For a missing
  comment, draft one from where the token is used and put it to the human to correct.
- **A part that is not what its name says** — named for the one screen that first used it;
  two parts doing one job; a part that is a variant of another. Recommend the generic name,
  or the part it should fold into.
- **A part held by one app that belongs to every app** — an app's own part that imports
  nothing app-specific, or that another app's screens redraw. Recommend moving it into the
  shared UI package, with what it needs passed in.

Where the opinion is guidance, the project's own value is its decision and never a
finding. The agent lists such differences apart, as **worth a look** — the guideline, the
project's value, and what adopting it would change — unless the line is marked
`design-choice`.

## Pass 2 — `project [path]` or `design <name or url>`: the work against the system

Run pass 1 first. While it has findings the human has not settled, stop and take those to
them.

Material: pass 1's design-system files, the inventory and the block types, plus the work:
- `project` — every UI source file under the folders `DESIGN_SOURCE_DIRS` names;
- `project <path>` — only those under `<path>`;
- `design` — the design's pages, read through the Artifact tool.

The agent classifies each finding:
- **The work departs from the system** — fix the work.
- **The system lacks what the work needs** — a role, a variant or a part the system gains.
  The block types and the inventory decide which.

A line already marked `design-accepted — <reason>` or `design-choice` is skipped.

## Settling the findings

Take each finding to the human one at a time, by `asking-questions.md`: what it costs,
what it risks, what it buys, and your recommendation. Each answer lands in the same pass:
- **A system change** — built into the tokens and parts, so the system now answers it.
- **A fix to the work** — made with the system's existing roles and parts.
- **Accepted** — a comment on the line, `design-accepted — <the human's reason>`
  (`/* … */` in CSS, `{/* … */}` in JSX), which every later audit skips.

A **worth a look** item goes to the human as a question, never as a violation: adopt the
guideline, or keep their own value. Keeping it needs no reason — the line is marked
`design-choice`, and no later audit lists it again.

## Report

How many files each pass inspected, each finding with its outcome, and anything left for
the human.

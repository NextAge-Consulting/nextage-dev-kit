---
description: Load the whole User Experience System before any kit work or advice on it — the project-side model, then the contracts that cross the kit's files and what each change moves
argument-hint: "[what you are about to change or advise on]"
---

@_claude-project/commands/uxes.md

---

# The kit's side

$ARGUMENTS

**Everything above is the instruction every project's session works under, and what a kit
change must keep true.** Its rule against changing the kit binds a project's session. Here
a kit file changes for one of two reasons: its code departs from a settled line below, or
the human — the kit's maintainer, in this session — directs the change.

A path the text above gives under `.claude/` is under `_claude-project/` here. The scripts
are in `_claude-project/skills/design-system/scripts/`, `ui-patterns/scripts/`,
`claude-design/scripts/` and `gitflow/scripts/`; the sync engine is
`_claude-maintainer/sync/sync-dev-kit.sh`. The kit has no UI and runs none of this: prove a
change with the suite beside each script you touched, and with the kit's gate
(`.claude/project-gate.sh`), which `/commit` runs.

## Settled

**Each line is a decision already made. Measure a fault report against them: code that
departs from one is a defect to fix. Only the human re-opens a line; when what they ask for
departs from one, say so before anything else, in the line's own words.**

- **The kit holds no design opinion.** A proposal about how something should look or
  behave belongs in a Design Pack or the project, never in a kit rule, skill or check.
- **The project conforms to the kit.** A project that fails a check, a generator or a
  migration is brought to the kit's conventions; the kit is never loosened to fit it.
- **What is approved is a design** — what shows, and how the app behaves — never a line of
  code as such. The line is only where a change is found and its answer recorded. No
  design change, no question: a comment, a header, an import or code that only moved
  judges nothing, an untouched line is never held to a rule, and a piece the human has
  approved or deferred is not asked about its own contents at a commit.
- **The changed line is the unit, and the locator decides what "changed" means.** The
  judge, the ledger's key and fingerprint, and the status check all take that from it.
- **Code decides what is mechanical; the judge is asked only what code cannot decide.** A
  judgement is never rewritten as a pattern check, and a new question ships with invented
  cases of both answers.
- **The judge gives a firm yes or no about one candidate, never a grade or a suggestion.**
  A question that drifts on its cases is rewritten or dropped.
- **The judge never refuses a commit; the status check refuses `/deploy`;** the commands'
  report step is where each yes is sorted, and the human hears the ones that change what
  shows or how the app behaves.
- **The status words are `pending`, `approved` and `deferred`.** A check says pass or fail,
  a judge yes or no; `approved` is the human's word alone. `deferred` is not `approved`.
- **A ledger item leaves on the human's word on the line, or when the line's code
  changes.** A later no removes nothing.
- **Every piece lands in exactly one kind, and every block in one type.** The types are
  generic kinds, each project designs its own look for each, and a project's piece is
  sorted into them, never added to them.
- **The stylesheet and the components are the system.** `design.md`, in the open DESIGN.md
  format the design tools read, and the Claude Design system are generated from them.
- **A report from anywhere but the human is unverified.** Reproduce it against the kit's
  code before acting on it, and state a cause only once you have.

## What a change moves

Find the row for what you are about to touch. Check everything in its second column, and
change in the same change whatever the edit makes untrue.

| Touch | Moves with it |
|---|---|
| What counts as changed — `codeChanges`, `importLines`, `anchor` in `locate.mjs`; `changedLines` and `screenBase` in `check-design-tokens.mjs` | `anchorLine` and `mergeLedger` in `judge.mjs`; the ledger's key (question, place, what it is about) and fingerprint; the status check's reading of the ledger; `design-judge.sh`'s cache key; a migration for the ledgers consumers already hold |
| `fingerprint`, `lineCode`, `excepted` in `check-ui-status.mjs` | `judge.mjs` and `locate.mjs`, which import them; the fingerprint on every ledger item; every `design-deferred` marker and deferred inventory line in every consumer, which carry their output — a migration |
| A judge question's fields in `judge-questions.md` | The candidate keys `locate.mjs` writes for it; its cases under `scripts/judge-fixtures/`; the passes table in `design-audit.md`; "What checks what" in the `design-system` skill; the handbook and the diagram |
| A candidate the locator finds, or stops finding | The question that reads it; the "What is not a question" list; the token checker, when the matter becomes mechanical or stops being so |
| `block-types.md` — a type, a neighbour, a Wraps cell | `block-types.mjs`, which parses it; the status check (a Type on the list); the token check (frame atoms a screen may not import); the locator (neighbours for the duplicate question); every consumer's inventory lines and `ui-block` headers — a rename or removal ships with its migration |
| A status word, a pointer's syntax, a reference's frontmatter | `headers`, `frontmatter` and `catalogueRows` in `check-ui-status.mjs`; the inventory template; the `design-system` and `ui-patterns` skills; every consumer's files — a migration |
| The inventory template | It syncs `merge`: text outside the regions replaces every consumer's; a region's name is its identity; `catalogueRows` reads the tables by their first backticked cell, a Status cell and a `Type` heading |
| The ledger's path or shape | `judge.mjs`, `check-ui-status.mjs`, `design-judge.sh`, and `code-fingerprint.mjs`, which leaves the ledger out of the code fingerprint so an approval re-runs no gate |
| When a check runs — `run_design_gate` and `run_headless_reviews` in `gates.sh`, the UI status gate in `deploy.sh` | The report steps of `commit.md` and `ship-main.md`; exit 22 in `deploy.md`; step 5 of the `design-system` skill's procedure; CI's design step; the diagram's WHEN column |
| A `DESIGN_*` key | `readKeys` in `check-design-tokens.mjs`, which the locator shares; `ui-sources.mjs`; the claude-design engine's config; `dest_for_kit_path` in the sync engine; the key's entry in `_claude-project/sync-substitutions.json`; the handbook's placeholder table |
| A token stylesheet convention — a purpose comment, the `publish:` markers, a role's shape | `check-design-tokens.mjs`, `claude-design/scripts/resolve.mjs`, `design-md.mjs` and the engine's build, which all read the same stylesheet and must never disagree about what it holds |
| A sentence in a skill, a rule or the inventory template that tells a project's session what to do | The same matter in `_claude-project/commands/uxes.md`, and in any migration `PROMPT.md` that gives the same instruction |

## How a change reaches a project

- **By sync alone,** when the project's own files stay valid under it.
- **With a migration,** when anything the project holds must change: a header, a status
  word, an inventory line, a ledger, a stylesheet convention. It ships in the same change
  (`.claude/rules/project/migrations.md`), brings the project to the kit, and never the
  reverse.

**A migration assumes every earlier one ran.** One that builds on the Claude Design engine,
the generated `design.md` or the `publish:` markers names that foundation in the paragraph
saying when it applies, and stops on a project that has a UI and lacks it.

## Keep true in the same change

`project-documentation/kitmaintainer-handbook.md` §12a, `project-documentation/uxes-layers.svg`,
`project-documentation/designer-handbook.md`, `project-documentation/ui-design-cheatsheet.md`,
`_claude-project/commands/uxes.md` and this file.

## Before you advise or change

**Open your reply with the lines the text above asks for, then these.** For a kit change,
`Layer` is the layers of a project's system the changed check or instruction acts on.

```
Kit decisions: "<each settled line the change rests on, quoted>"
Moves: <each row of the table the change touches, and what in its second column you will change>
Reaches projects by: <sync alone | a migration — and what it changes in them>
```

Then read end to end every kit file those rows name, before the first edit.

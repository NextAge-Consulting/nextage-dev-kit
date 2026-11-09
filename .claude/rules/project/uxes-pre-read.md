# Read the User Experience System Whole Before Touching Any of It (Zero Tolerance)

The User Experience System is one mechanism spread over many files: code locates
candidates, the judge answers them, the ledger holds the yeses, the status check reads the
ledger, `/deploy` refuses on the status check, and the gitflow gates decide when each
runs. Read the whole before proposing or editing anything under
`_claude-project/skills/design-system/**`, `_claude-project/skills/ui-patterns/**`,
`_claude-project/skills/claude-design/**`, `_claude-project/rules/ui-design.md`,
`_claude-project/rules/ui-patterns.md`, `_claude-project/templates/ui-inventory.md`,
`_claude-project/commands/design-audit.md`, `design-judge.sh`, `run_headless_reviews` in
`gates.sh`, the design judge's lines in `commit.md` and `ship-main.md`, the UI status gate
in `deploy.sh`, or a `uxes-*` migration. Paths from the kit
root; the handbook by its section, everything else end to end:

- `project-documentation/kitmaintainer-handbook.md` §12a, with `project-documentation/uxes-layers.svg`
- `_claude-project/skills/design-system/SKILL.md`, `references/judge-questions.md`, `references/block-types.md`
- `_claude-project/skills/ui-patterns/SKILL.md`
- `_claude-project/skills/design-system/scripts/locate.mjs`, `judge.mjs`, `check-design-tokens.mjs`; `_claude-project/skills/ui-patterns/scripts/check-ui-status.mjs`
- `_claude-project/skills/gitflow/scripts/design-judge.sh`, `run_headless_reviews` and the fingerprint helpers in `gates.sh`, `code-fingerprint.mjs`, the UI status gate in `deploy.sh`
- `_claude-project/commands/design-audit.md`, and the design judge's lines in `commit.md` and `ship-main.md`
- `_claude-project/rules/ui-design.md`, `_claude-project/rules/ui-patterns.md`, `_claude-project/templates/ui-inventory.md`
- `_claude-maintainer/migrations/uxes-model/PROMPT.md`, the shape a model change ships in

Name which of these you have loaded in the sentence before the proposal.

## The contracts that cross files

- The changed line is the unit, and the locator decides what "changed" means; the judge,
  the ledger's key and fingerprint, and the status check all take that from it.
- The status words are `pending`, `approved` and `deferred`. A check says pass or fail, a judge
  yes or no; "approved" is the human's word alone.
- The judge never refuses a commit; the status check refuses `/deploy`; the commands' report
  step is where the human hears the yeses.
- A ledger item leaves on the human's word on the line, `design-accepted` or
  `design-deferred`, or when the line's code changes.
- Code decides what is mechanical; the judge is asked only what code cannot decide, and a
  new question ships with fixtures of both answers.
- The kit holds no design opinion. A proposal about how something should look or behave
  belongs in a Design Pack or the project, never in a kit rule, skill or check.

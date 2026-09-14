# /handoff

Write the session handoff at `project-documentation/temporary/handoff.md`, and sweep the temporary folder while you are there.

This command only WRITES. The next session's `/work` reads the file — there is no read mode here.

$ARGUMENTS

## What the document is

One page, written for the next session's AI. It is **rewritten in full every time** — never appended to, never a running log, never a changelog. The human gets a TLDR in the conversation and can open the file if they want more.

It carries no git state: no branch name, no file counts, no last commit. That information is stale the moment the next `/commit` runs, and `git log` / `git status` give it back for free.

## Procedure

### Step 1: Read the outgoing handoff

Before writing anything, read the existing `project-documentation/temporary/handoff.md` if there is one. Every open item in it gets classified in Step 3.

**Building the new document blind to the old one is the failure this command exists to prevent.** A session that worked three of four outstanding items must not drop the fourth by never mentioning it.

### Step 2: Sweep the temporary folder

List every file in `project-documentation/temporary/`. For each one other than `handoff.md`, decide spent or live:

- **Spent** — the work it describes has landed. Follow `rules/development-guidelines.md`: write the durable facts present-tense into the right permanent doc under `project-documentation/`, then delete the file. Not everything needs promoting; a fact the code states plainly needs no doc. Never write what something *was*, what replaced it, or that it was removed (constitution §XV).
- **Live** — leave it. If its own state header no longer matches what actually happened, correct the header.

The outgoing handoff from Step 1 gets the same treatment before it is overwritten. It is the file most likely to hold a durable fact that was never written down anywhere else.

`handoff.md` itself is never swept and never retired. It lives in `temporary/` permanently and is replaced each session.

### Step 3: Classify every open item from the outgoing handoff

Three resolutions. There is no fourth, and silence is not one of them.

| Resolution | Requires | Carry-over |
|---|---|---|
| **Done** | Evidence from this session — the work happened, or it is visible in the tree. Not "it looks finished." | None. Documented per Step 2 where durable. |
| **Carried** | Nothing. This is the default. | The item, with any completed portion recorded and the remainder stated as what is left. |
| **Dropped** | A stated reason — superseded by X, overtaken, no longer wanted. If you cannot justify it in a clause, you cannot drop it. | None. |

**An item carried unchanged into a third consecutive handoff gets flagged**, in the document and in the TLDR: `open since <date>, unmoved — still relevant?` That is the trimming pressure, and it is aimed at the human, who is the one who can answer. Without it the document grows into a backlog nobody prunes.

### Step 4: Write the file

Replace `project-documentation/temporary/handoff.md` entirely.

Three sections are mandatory — the date stamp, what happened, and the document index. Everything else is present only when it has real content.

```markdown
# Handoff — YYYY-MM-DD

*Written YYYY-MM-DD HH:MM Area/City (ABBR, UTC±HHMM) · YYYY-MM-DD HH:MM UTC*

## What happened last session

<Prose. What was done and where it landed. Not a commit list.>

## Open questions

<Each marked blocking or not. If not blocking, name the default already applied.>

## Next steps

<The first concrete action, not a backlog.>

## Blockers

<Each with exactly what unblocks it, and who holds it.>

## Assumptions taken

<Anything decided without asking, so a wrong one is a one-line correction.>

## Documents, and when to read them

| Document | Read it when |
|---|---|
| `<path>` | `<the situation that sends you there>` |
```

**Stamp both zones, and name the local one.** A handoff written in one timezone and
compared against a git log in another reads as a gap that is not there. The local zone
also cannot be inferred — not from the project's language, not from the client's country,
not from the codebase. So the H1 carries the local date for reading, and the line beneath
it carries the full local time with its IANA zone name alongside the same instant in UTC.
A human compares against the local stamp; anything comparing against git, GitHub or CI
compares against the UTC one.

Generate the whole header rather than hand-typing any part of it:

```bash
TZNAME=$(readlink /etc/localtime 2>/dev/null | sed 's|.*/zoneinfo/||'); TZNAME=${TZNAME:-${TZ:-unknown}}
printf '# Handoff — %s\n\n*Written %s %s (%s) · %s*\n' \
  "$(date +%F)" "$(date +'%F %H:%M')" "$TZNAME" "$(date +'%Z, UTC%z')" "$(date -u +'%F %H:%M UTC')"
```

**Never manufacture content to fill a heading.** A session can finish its work with nothing outstanding, and that is a complete handoff: a date, a paragraph on what was done, and the index. If there are no blockers, the Blockers heading is absent — not present and empty. An invented next step is worse than a missing section, because the next session will act on it.

The index is the highest-value section. The handoff points at the durable docs rather than restating them; that is what keeps it from decaying into a history.

### Step 5: TLDR to the human

A few lines: what the document now says, what the sweep promoted and deleted, and any item flagged as unmoved. Not a recital of the file.

## Blocking conditions

- No `project-documentation/` directory — this project has not adopted the convention. Say so rather than creating one silently.

## Related

- `rules/development-guidelines.md` — where documents live, and the rule that a spent plan is rewritten present-tense and deleted.
- `constitution.md` §XV — present-tense documentation.
- `/work` — reads this file at session start.
- `/autonomous` — ends by running this command.

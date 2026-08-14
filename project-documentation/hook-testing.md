# Testing the Kit

The kit ships hooks — small shell programs that sit in the path of every tool call on
every machine that syncs them. This document covers how they are tested, and why that
looks almost nothing like a test suite for a production app.

Companion to `hook-patterns.md` (how hooks are written) and
`.claude/rules/project/dev-kit-workflow.md` (how kit changes propagate).

---

## Why the kit needs its own kind of suite

A normal app test suite protects a running system: it fails, someone sees red, the
build stops. The kit has none of that leverage, for three reasons.

**A broken guard fails OPEN, and silence is what success looks like too.** Every guard
here signals "allow" by producing no output and exiting 0. That is byte-for-byte what
a guard that crashed, mis-parsed its input, or matched nothing produces. A hook can be
completely inert for months and the only symptom is the absence of a block nobody was
expecting. There is no crash, no log line, no red — and the thing it was protecting is
now unprotected, quietly.

**The blast radius is every project at once.** A defect in an app breaks that app. A
defect in a kit hook lands on every consumer at their next sync, and it lands wearing
the authority of shared tooling nobody re-reads.

**The environment is the bug.** Kit hooks are shell, running on developer Macs against
BSD userland. The defects found in practice were not logic errors, they were
*portability and encoding* errors — the exact class that a Linux CI runner certifies as
healthy. More on this below, because it determines where the tests run.

---

## The convention

**A file `X.<ext>` is tested by a sibling `X.test.sh`.**

That is the entire contract. No registry, no runner to keep in sync, no config listing
which files have coverage. Drop a `X.test.sh` next to anything and it is wired up from
that moment.

```
.claude/hooks/
  git-guard.sh
  git-guard.test.sh        ← tests the file beside it
  npm-guard.sh
  npm-guard.test.sh
```

Each suite is standalone: plain `bash`, no framework, no dependencies beyond `python3`
(already required — the hooks themselves use it). Run one directly at any time:

```bash
./.claude/hooks/git-guard.test.sh          # exits 0 green, 1 red
```

Run them all:

```bash
for f in .claude/hooks/*.test.sh; do "$f" >/dev/null || echo "FAILING: $f"; done
```

---

## When they run: on edit, not on CI, not on sync

`test-on-edit.sh` is a `PostToolUse` hook on `Edit|Write|MultiEdit`. When a file is
changed, it looks for the sibling suite and runs it. Green is silent. Red exits 2,
which delivers the failing cases straight back into the session that caused them.

The two obvious alternatives were both considered and are both wrong here.

**CI is the wrong place**, and this is the finding that set the whole design. The
defect that motivated the suite was `own-it-guard.sh` matching with `\b` in `sed` —
supported by GNU sed, **not** supported by the BSD sed that ships on macOS. The hook
was completely inert on every Mac in the shop. An ubuntu runner would have gone green
on it, indefinitely, and certified the breakage as healthy. A platform difference is
only catchable on the platform. CI on Linux would have actively concealed this one.

**Sync is the wrong time.** Running the suites when a consumer pulls updates tests
files nobody just touched, attributes any failure to whoever happened to sync next,
and puts the report in front of a person with no context for it. On edit, the failure
lands in front of the person who caused it while they still have the context to fix
it — which is the only moment a test result is cheap to act on.

Escape hatch, for one command: `TEST_ON_EDIT=off`.

---

## What every suite covers

Four sections, in this order. The order is deliberate — the allow cases come before
the deny cases in importance, which is the opposite of the intuition.

### 1. MUST ALLOW — the cases that matter most

A guard that blocks legitimate work gets bypassed, disabled, or routed around within a
day, and then it protects nothing. A false block is strictly worse than a missing
block, because it burns the credibility of the whole mechanism.

So every suite pins the things that must keep working: `git checkout -b` (gitflow
itself runs it), `npm ci`, `npm run dev`, editing a `template`-mode file the project
owns, `console.log` in a project with no pino dependency.

### 2. MUST DENY — the behaviour the hook exists for

The straightforward half. One case per pattern the guard matches, plus the compound
forms (`cd x && <bad thing>`) that a naive matcher misses.

### 3. Deny payload must be valid JSON

**This is the section that found the most bugs, and it is not obvious.**

Guards signal a block by printing a `permissionDecision: deny` payload. If that JSON
is malformed, it is silently discarded and the command runs. The guard looks like it
is working — it matched, it emitted, it exited 0 — and it blocks nothing.

Four of the eight hooks built their JSON by interpolating the command string into a
heredoc. Any command containing a double quote produced an unparseable payload:

```
npm run db:generate -- --name="add user table"   ← the normal way to name a migration
pkill -f "npm run dev"                            ← the exact thing the guard exists to stop
console.log("she said \"hi\"")                    ← user source, quotes guaranteed
```

The fix is uniform: emit through a real JSON encoder, never string interpolation. The
regression case is now permanent in every suite.

### 4. Degenerate input

Malformed JSON, empty payload, missing keys, null values. A hook sits in front of
every tool call; one that dies on unexpected input wedges the session. These must all
exit cleanly.

---

## Escape hatches are tested, because they silently didn't work

Every guard documents an override — `SKIP_GIT_GUARD=1`, `SKIP_NPM_GUARD=1`,
`SKIP_SERVER_GUARD=1` — as a **command prefix**.

Two hooks tested the *environment variable* instead:

```bash
if [ "$SKIP_NPM_GUARD" = "1" ]; then exit 0; fi     # never true
```

A prefix sets the variable for the command's own process. The hook runs in Claude's
environment and never sees it. The documented escape hatch had never worked in either
hook — discovered only by a test asserting the documented behaviour rather than the
implemented behaviour.

The correct form checks the command string, keeping the env test as a secondary path:

```bash
if [ "${SKIP_NPM_GUARD:-}" = "1" ] || printf '%s' "$COMMAND" | grep -q "^SKIP_NPM_GUARD=1"; then
    exit 0
fi
```

**Test the contract as documented, not as coded.** Reading the implementation to
decide what to assert reproduces its bugs as its specification.

---

## Environment-dependent hooks must control their environment

Several hooks branch on machine state, so a suite that inherits the machine tests only
one branch — and on the maintainer's machine, usually the vacuous one.

| Hook | Depends on | The suite must |
|---|---|---|
| `block-kit-edit.sh` | `~/.claude/kitmaster` (maintainer → inert) | Redirect `HOME` at temp dirs and test **both** machine kinds |
| `block-console-log.sh` | a pino dependency in cwd's `package.json` | `cd` into purpose-built temp projects |
| `npm-guard.sh` | `package-lock.json` in the payload cwd | Build both a locked and a fresh temp dir |
| `block-drizzle-handroll.sh` | `meta/_journal.json` beside the target | Build a real drizzle dir and a look-alike |

Without the `HOME` redirect, every guarded case in `block-kit-edit.test.sh` passes on
the maintainer's machine by doing nothing at all — a green suite proving nothing, which
is worse than no suite, because it is trusted.

---

## Writing a new hook

1. Write `X.sh` and `X.test.sh` together. Allow cases first.
2. Emit any deny payload through `python3 -c 'json.dumps(...)'`. Never a heredoc.
3. Cover all four sections above.
4. Point the environment at temp fixtures — never at the repo or the real `$HOME`.
5. Register in `settings.json` and add both files to the sync manifest as `owned`.
6. Propagate all three copies byte-identical: kit source, kit dogfood, consumer.
   Run the suite **from the consumer copy** — that is the one that runs in anger.

---

## Standing rule

**A hook change without a green suite is not done.** `test-on-edit.sh` enforces this
for anything already covered; for anything new, the coverage is the author's to write.

The reason to hold the line: every defect in this document was invisible. Nothing was
red. Nothing crashed. Four guards were emitting unparseable denies, two escape hatches
had never worked, one pattern had a `$` anchor where a literal was intended, and one
hook was inert on every Mac in the shop. All of it passed a reading. None of it
survived a test.

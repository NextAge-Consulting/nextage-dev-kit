# Autonomous Sessions (Zero Tolerance)

**This file is the single definition of "autonomous" for the whole rule set.**
Other rules that change behaviour when nobody is watching point here rather than
defining it again.

## Autonomous is ONE TURN — that is the whole point

**Autonomous mode is scoped to a single turn.** It begins when the human
declares it and **ends when you hand back.** It is not a state that persists
across the conversation, and the next turn is interactive again unless the human
says otherwise.

Its entire purpose is to **extend that one turn** until the work is finished —
which is exactly why the rules below are what they are. Every stop ends the
turn, and ending the turn ends the mode: a session that halts at twenty minutes
to report progress has not paused an autonomous run, it has *finished* one,
twenty minutes in, with the work undone.

So there is nothing to "stay in" and nothing to switch off. Deliver the whole
body of work, hand back, and you are interactive again by definition.

## The mode is ASSERTED, never inferred

A turn is **autonomous** only when one of these is true:

- It was launched unattended — a cron / scheduled run.
- The human said so **in this conversation**: handing over a body of work and
  stating they are stepping away ("execute this plan, I'm out for the night,
  have it done when I get back").

**Everything else is interactive, including a long silence.** A background job
is NOT autonomous by virtue of being a background job — the human may be
watching it live. Nor is a big task, a plan you agreed, or a night-time
timestamp.

**Never infer the mode from tone, quiet, or the size of the work.** Guessing
wrong is costly in both directions, which is why the default is the safe one:

| Wrong guess | What it costs |
|---|---|
| Inferred autonomous, human was watching | You stop checking in on work they wanted to steer, and they discover the divergence at the end |
| Inferred interactive, human had left | You stop at the first blocker — costing **every hour until they next look at the screen**, with the rest of the work untouched |

If it genuinely matters and the mode was never stated, ask once, early, and
proceed interactively until answered.

## Write the mode down — the turn outlives your context of it

**The mode is almost always declared MID-conversation** — a design discussion
that ends with "execute this, I'm out" — so there is no launch flag that could
carry it, and nothing structural marks the turn. It lives in context, and a long
turn gets summarized. The sentence that set the mode can simply be gone by the
time the work is half done, and the failure is silent and expensive: you revert
to interactive and stop at the first thing you would otherwise have worked
around.

So the moment a turn is declared autonomous, **write a line into the plan or
task document the work runs off** — that it is autonomous, and the date — then
continue. A file survives compaction and a context clear; a conversation does
not.

**Clearing that line is part of handing back.** The mode ended when the turn
did, so a document still claiming to be autonomous is now false, and the next
session to read it — exactly the one that lost the conversation — would suppress
check-ins the human is waiting for. Flip it or delete it in the same pass as the
final report.

**If a plan document does not exist, that is the signal to write one.** A body of
work big enough to hand off unattended is big enough to be written down, and the
handoff itself is the moment it stops being optional.

## The shape of every autonomous session

**The goal is completion of the agreed body of work — all of it — handed back
ready for testing.** Not a progress report, not a first phase, not "the
foundation is in place."

`working-discipline.md` already governs this for ALL work — goals are fixed,
judgment applies only to the *how*, and being unmonitored *tightens* the
instructions rather than loosening them. It is not restated here. What follows
is only what is specific to nobody being there.

## Never stop to report progress

**There is no check-in.** Do not stop to say a phase is done, to confirm the
approach is still right, to ask whether to continue, or to offer a choice you
could make yourself. The human is not there. A turn that halts at 20 minutes to
announce progress has converted an eight-hour run into a twenty-minute one.

Narration in passing is fine and often useful — a line about what just landed as
you move to the next thing. **Narration that ends the turn is the failure.**

| Forbidden | Instead |
|---|---|
| "Phase 1 complete — shall I continue?" | Continue. Report at the end. |
| "This is a good place to pause for review." | There is no reviewer. Keep going. |
| "Before I proceed, confirming the approach…" | The approach was agreed at handoff. Proceed. |
| Ending the turn on a question you could answer yourself | Answer it, note the assumption, keep working. |

## A blocker stops THAT work — never the turn

**When something is genuinely blocked, set it down and pick up the next thing.**
Then keep going. A blocker is a fact about one item, not a verdict on the run —
and stopping on it ends the turn, which ends the mode.

1. Record the blocker: what is blocked, why, and precisely what you need.
2. Move to the next item that does not depend on it.
3. **Do every other piece of work in full**, including work that merely looks
   adjacent to the blocked one.
4. Present **every** blocker together in the final report.

**Batching is the point.** Three blockers surfaced one at a time cost three
human round trips, each one arriving hours after the last. Surfaced together
they cost one. If the human returns to a session that stopped on the first
blocker with seven items of unrelated work still untouched, the session failed
even if the blocker was real.

**"Blocked" means work cannot proceed under ANY assumption** — a missing
credential, an access you cannot grant, a decision where guessing wrong would be
unsafe or would waste the work. It does NOT mean a decision is merely awkward.
When a reasonable default exists: take it, write down the assumption, keep
working, and list the assumption in the final report so it can be reversed
cheaply.

## Verify your own work — there is nobody to hand it to

`testing-verification.md` reserves testing for the human in interactive
sessions. **An autonomous turn inverts that**, and that rule says so. Drive the
browser, run the flows, run the suite, and work through the failures. "Ready for
testing" means you have already tested it and it works, not that it compiles.

## Finish clean

Before the final report: no half-finished states, no `TODO` left in place of
work that was in scope (`working-discipline.md`), no servers you started still
running (`dev-server.md`), no scratch files in the tree.

## The final report

One report, at the end, containing:

- **What was completed**, plainly enough to act on.
- **What was verified**, and how — the actual commands and their results.
- **Every blocker**, together, each with exactly what is needed to unblock it.
- **Every assumption** taken in place of a decision, so any wrong one is a
  one-line correction rather than an archaeology exercise.
- **Anything found and left unfixed** (constitution §XII), which after an
  autonomous turn should be close to nothing.

**Why this rule exists**: the failure mode is not laziness, it is misplaced
diligence — stopping to confirm, to report, or to ask reads as conscientious and
is the single most expensive thing an unattended turn can do — because the stop
IS the end of it.

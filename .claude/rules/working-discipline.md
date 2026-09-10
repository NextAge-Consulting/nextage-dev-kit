# Working Discipline

**A stated goal or instruction is a hard requirement. Judgment governs HOW to reach it, never WHETHER to.**

Being unmonitored tightens the instructions rather than loosening them. The human is trusting the work gets done as specified precisely because no one is there to catch a deviation.

Judgment belongs on the path, including the unglamorous parts — stand up the server, build the fixtures, fix the broken flow first. "This needs more scaffolding than expected" is a reason to build it.

Judgment never lands on whether to do the work at all. Downgrading a goal because it is hard, entangled or multi-step — "run the full suite" to "a smoke test is fine", "finish it" to "defer as a follow-up" — is the one place it must not go. Prudence and avoidance look identical from the inside; default to doing it.

## Once it's agreed, finish it

Work a settled approach through to completion. The check-in happens while deciding the approach, not while carrying out an agreed one.

Finish the whole assignment. Splitting scope is the human's call.

A plan's deferred or consider-later items get an explicit include-or-exclude decision when you reach that point in the build.

A `TODO` is never a way to dodge work you don't feel like doing. Code one only at the human's express direction.

## Follow the reference before you form an opinion (Zero Tolerance)

**When a comment, rule, doc or error message names a reference, OPEN IT before
acting on that topic.** Not after forming a view, not to confirm one — before.

A citation exists because someone already did this work and wrote down the
answer, the reasoning and the measurements. Reading the citing line and skipping
the cited file means re-deriving all three from a one-line summary, and a
summary is lossy in the direction that matters: it keeps the conclusion and
drops the evidence, so what you rebuild is confident and unsupported.

The tells, all of them cheap to notice:

- You are about to explain WHY something is the way it is, from a code comment.
- You are about to call an existing choice wrong, a workaround, or a bug.
- You are about to propose a rule, guard or standard covering ground a reference
  already names.
- You catch yourself writing "this appears to be" about a decision someone made
  deliberately enough to document.

**A settled decision is not re-opened by a fresh reader.** If the reference
answers it, that is the answer — cite it and move. If you believe the reference
is wrong, say so against what it actually claims, with evidence it does not
already address. Disagreeing with a paraphrase of it is not disagreeing with it.

**Check the claim against reality before repeating it OR contradicting it.** A
reference asserting "every project already does X" is a measurement that was
true once. Verify it. This rule was written after a session spent re-deciding a
question `deployment.md` had already settled — reached by reading a
`vite.config.ts` comment that pointed straight at it, and never opening it. The
same session then over-corrected, declaring the settled answer wrong on the
strength of the same unread reasoning. Both directions cost the same hour.

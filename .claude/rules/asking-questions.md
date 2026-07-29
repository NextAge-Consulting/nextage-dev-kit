# Asking Questions (Zero Tolerance)

**When you need input from the human, default to plain natural-language prose, ONE
question at a time. `AskUserQuestion` (the multiple-choice chip UI) is permitted
ONLY when there is exactly ONE decision on the table and it's a genuinely closed
pick where discussion is unlikely. More than one question → prose, period.**

## The two invariants (these never bend)

1. **Multiple decisions → prose, period.** If you have two or more things to ask
   to move forward, ask them in prose, one at a time, waiting after each. Do NOT
   use `AskUserQuestion`, and do NOT batch them in prose either. The reason is
   twofold: the discussion of Q1 almost always reframes, answers, or dissolves
   Q2/Q3; and the mere fact that a moment is big enough to need several questions
   means the human will almost certainly want to discuss at least one of them. A
   multi-question `AskUserQuestion` call is always wrong.
2. **When discussion is plausible, start in the discuss stance (prose).** If
   there's a real chance the human pushes back on the premise, adds context, or
   picks a fourth thing, the chip UI fights that. Begin in prose so the room is open.

## When `AskUserQuestion` IS allowed

ALL of these must hold:
- There is exactly **one** decision to make (per invariant 1 — never a batch).
- The options are a **genuinely closed, concrete set** — mutually exclusive
  (or a clean multiselect), exhaustive, no obvious "fifth thing."
- Discussion is **unlikely** — a straight pick, not a judgment call the human will
  want to reason about out loud.

Good fits: "Run E2E now?" (Yes/No). "Which env?" (staging / prod).
A lone routing pick. (A pick whose single answer opens exactly one follow-up
pick — e.g. Yes → which scope — is still one-at-a-time and fine; a slate of
independent decisions is not.)

## When to use prose instead (the discuss stance)

- **Designing, planning, speccing, spit-balling, fleshing out ideas, reviewing a
  plan.** Conversations, not forms. High chance the human takes "let's discuss."
- **Any time there's more than one decision** — see invariant 1.
- Anything where the *premise* might be wrong, or "it depends" is a likely answer.
- **Reviewing or building a plan** — discuss a change in prose *before* editing the
  plan file. Don't silently rewrite the plan doc mid-conversation.
- **When in doubt, prose.** A needless chip UI (premise pre-committed, discussion
  suppressed) costs more than one extra prose round-trip.

## What good looks like

- Recommend a default in the same breath as the question, so the human can say "yes"
  or redirect. ("I'd keep the schema monolithic and split lazily — that work? Or
  full per-file split up front?")
- After the human answers, *then* surface the next decision if it still stands.

| Forbidden | Why | Fix |
|-----------|-----|-----|
| `AskUserQuestion` with 2+ questions | Q1's answer reframes the rest | Prose, one at a time |
| Reaching for `AskUserQuestion` when you have several decisions | Multiplicity means at least one wants discussion | Prose, one at a time |
| `AskUserQuestion` during design/plan/spec/review | Closed chips suppress the discussion the human wants | Prose, recommend a default, let them react |
| `AskUserQuestion` when "it depends" is likely | Premise pre-committed | Prose; surface the trade-off |
| Batching questions in prose ("I have a few questions:") | Same batching failure | Pick ONE; ask the rest later if still needed |

**Violating the two invariants — batching/multiplexing questions, or dropping
into the chip UI on a discussable decision — is a critical error.**

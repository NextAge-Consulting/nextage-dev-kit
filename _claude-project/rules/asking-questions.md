# Asking Questions

**When you need input from the human, ask in plain prose, one question at a time, and wait.** This rule governs which mechanism carries a question. Where the question sits in the reply lives in the `house` output style.

## Two invariants

**Multiple decisions → prose, one at a time.** Never `AskUserQuestion`, and never batched in prose either ("I have a few questions:"). The discussion of Q1 usually reframes, answers, or dissolves Q2.

**When discussion is plausible, start in prose.** If the human might push back on the premise, add context, or pick a fourth thing, the chip UI fights that.

## When `AskUserQuestion` is allowed

All three must hold: exactly one decision; a genuinely closed, mutually exclusive set with no obvious fifth option; discussion unlikely. Good fits — "Run E2E now?" (yes/no), "Which env — staging or prod?"

## When to use prose

Designing, planning, speccing, spit-balling, reviewing a plan. Anything where the premise might be wrong or "it depends" is a likely answer. Discuss a plan change in prose before editing the plan file. When in doubt, prose.

## Every option carries its consequence

**A bare A-or-B is not a question.** It hands the human the analysis you already did and threw away. Each option gets, in a line or two:

- **What it costs** — work now, work later, money, or complexity that stays.
- **What it risks** — what breaks, what you are betting on, what is hard to undo.
- **What it buys** — the actual reason anyone would pick it.

Then say which one you would take and why. A recommendation makes "yes" a valid answer.

The cost sits with the option, not in a later paragraph. Translate mechanism into outcome — "use X or Y?" tells the human nothing about what changes for them.

**The tell:** you write "do you want X or Y?" and the sentence before it does not already explain how X and Y differ in outcome.

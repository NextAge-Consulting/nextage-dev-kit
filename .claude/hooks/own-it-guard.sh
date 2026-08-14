#!/usr/bin/env bash
# own-it-guard.sh — Stop hook. The last line of defence for constitution §XII.
#
# WHAT IT CATCHES
#   A sign-off that hands the human a defect or an omission instead of a fix.
#   The failure is reliably marked in language, which is the only reason a text guard
#   is viable here at all.
#
# WHAT IT DOES NOT DO
#   It does NOT police a vocabulary. A word list against a model that can paraphrase is
#   a race the list loses — and worse, it would teach AVOIDING THE MENTION rather than
#   doing the work, which is strictly worse than the problem: the defect goes from
#   unfixed to invisible.
#
#   So the phrases are only a TRIGGER. What they trigger is a forced classification:
#   name the item, DONE or BLOCKED. That survives paraphrase, because the rule admits
#   exactly two values and "I mentioned it" is not one of them. If the work really was
#   done, answering costs one line and the guard was harmless.
#
# WHY THE MATCHING IS IN PYTHON
#   It was in sed, and it was silently broken: BSD sed (macOS) does not support `\b`,
#   so the negation stripping never ran and the guard fired on "NOT deferring anything".
#   python3 is already required here to parse the hook payload, so the whole text pass
#   lives there — portable, and testable without a shell.
#
# EXIT SEMANTICS
#   exit 0 → nothing matched; the turn ends normally.
#   exit 2 → blocks the stop; stderr IS delivered to Claude in full. Verified live
#            2026-08-14: the guard fired mid-session, the message arrived, and the model
#            answered the classification. Hooks also load immediately — no restart.
#
#   Set OWN_IT_GUARD=off to disable for one command.

set -uo pipefail

[ "${OWN_IT_GUARD:-on}" = "off" ] && exit 0

hit=$(python3 -c '
import json, re, sys

try:
    msg = json.load(sys.stdin).get("last_assistant_message") or ""
except Exception:
    sys.exit(0)
if not msg.strip():
    sys.exit(0)

# Only the closing stretch. Mid-reply these phrases are usually legitimate narration;
# it is the SIGN-OFF that decides whether something was handed over unfixed.
text = msg[-1200:]

# An explicit classification means the work was already accounted for.
if re.search(r"\b(DONE|BLOCKED)\b\s*:", text):
    sys.exit(0)

# 1. Drop QUOTED spans — backticks, straight and curly quotes. Discussing a phrase is
#    not using it. The guards first live firing was exactly this: a rule phrase quoted
#    while editing the rule. Punishing that teaches avoiding the subject.
text = re.sub(r"`[^`]*`", " ", text)
text = re.sub(r"\"[^\"]*\"", " ", text)
text = re.sub(r"[“][^”]*[”]", " ", text)

# 2. NEGATION is checked per MATCH, by proximity — see step 4.
#
#    Two earlier attempts failed on real sentences. A fixed CHARACTER WINDOW after the
#    negator could not span two negations in one sentence. Dropping the whole SENTENCE
#    over-corrected and let the canonical failure through:
#    "None blocks the hardware contract, so I have left them for a separate pass" —
#    the "None" there negates nothing about the hand-over that follows it.
#
#    What actually holds: a negator only negates a phrase it sits NEXT TO. So the
#    lookback happens at the match, not before it.

# 3. High-signal deferral markers only. Deliberately NOT included, because the session
#    corpus showed them frequent but usually innocent: "for now", "didn.t touch",
#    "already there", "predates", "follow-up". A guard that cries wolf gets routed
#    around, and routing around it means saying less.
PATTERNS = [
    r"defer(?:red|ring)?\s+(?:it|that|this|the|them|to|as)",
    r"\bdeferring\b\s+\w+",
    r"left\s+unfixed",
    r"out\s+of\s+scope",
    r"outside\s+the\s+scope",
    r"lower\s+priority",
    r"load.?bearing",
    r"worth\s+(?:noting|flagging)\s+(?:rather|instead)",
    r"flagging\s+(?:it|this)\s+rather",
    # NOT included: bare "rather than fixing" / "instead of fixing". Both are
    # legitimate far more often than not ("rather than fixing it piecemeal I rewrote
    # the module"), and the real corpus case — "flagging it rather than fixing it" —
    # is already caught by the two narrower patterns above.
    r"next\s+touch",
    r"separate\s+(?:PR|issue|pass)\s+(?:for|instead)",
    r"its\s+own\s+(?:PR|issue|piece)",
    r"unrelated\s+to\s+(?:this|the|today)",
    r"(?:leaving|left)\s+(?:it|that|this|them)\s+(?:alone|as\s+is|for)",
    r"pre-?existing[^.]{0,45}(?:so|and)\s+(?:i|we)\s+(?:left|leave)",
]
# 4. A negator within ~40 characters BEFORE a match negates it. That is about six
#    words — close enough to be the same clause, short enough that a negation earlier
#    in the sentence about something else does not launder a real hand-over.
NEG = re.compile(
    r"\b(?:not|never|no|none|nothing|neither|without|avoided|avoiding|avoid|"
    r"instead\s+of|rather\s+than|isn.t|aren.t|wasn.t|didn.t|don.t|won.t)\b", re.I)

found = []
for p in PATTERNS:
    for m in re.finditer(p, text, re.I):
        if NEG.search(text[max(0, m.start() - 40):m.start()]):
            continue
        hit_s = " ".join(m.group(0).split())
        if hit_s.lower() not in [f.lower() for f in found]:
            found.append(hit_s)
print(", ".join(found))
' 2>/dev/null <<<"$(cat)")

[ -z "$hit" ] && exit 0

cat >&2 <<EOF
🛑 §XII CHECK — your closing text contains: ${hit}

Those phrases usually mark work handed over instead of done. They are a trigger, not
an accusation — if you already fixed it, this costs you one line.

There are exactly TWO legal states for anything you were asked to do, and for any
defect you found along the way:

  DONE:    fixed, in this body of work.
  BLOCKED: cannot proceed under ANY assumption without a human decision or access.
           Name precisely what you need.

Not legal: lower priority, out of scope, not load-bearing, unrelated to this change,
worth flagging, a follow-up. Relatedness is not a scope test — we do a BODY OF WORK
regardless of how the pieces relate (constitution §XII).

If you can describe a defect precisely enough to write it down, you have everything
you need to fix it. The write-up costs the same information and leaves it broken.

Reply with each item as "DONE: <what>" or "BLOCKED: <what you need>", then continue.
EOF
exit 2

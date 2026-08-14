#!/usr/bin/env bash
# Regression suite for own-it-guard.sh. Run after ANY change to the patterns.
#
# Every case here came from a real session, not from imagination. The MUST-PASS half
# matters more than the MUST-BLOCK half: a guard that cries wolf gets routed around,
# and routing around this one means saying less about defects, which is worse than the
# problem it exists to solve.
set -uo pipefail
H="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/own-it-guard.sh"
fail=0
t(){ printf '{"last_assistant_message":%s}' \
      "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$2")" \
    | "$H" >/dev/null 2>&1
    r=$?; if [ "$r" = "$1" ]; then echo "  ✓ $3"; else echo "  ✗ FAIL (exit $r, want $1) — $3"; fail=1; fi; }

echo "MUST PASS (legitimate sign-offs):"
t 0 'I was quoting a rule phrase, not deferring anything. All three are built.' 'negated: not deferring'
t 0 'Everything is done, nothing left unfixed and nothing out of scope was skipped.' 'negated: nothing x2'
t 0 'No work was deferred to a later pass and none of it is out of scope.' 'negated: no / none'
t 0 'Fixed the encoder and the reaper window. Tests green, nothing committed.' 'clean sign-off'
t 0 'I did not touch kit git — no commits, per your rule.' 'compliance report'
t 0 'The rule forbids saying "out of scope" in a sign-off.' 'quoted phrase'
t 0 'DONE: fixed the redirect while I was in there.' 'already classified'
t 0 'Rather than fixing it piecemeal I rewrote the whole module.' 'rather-than, positive'
t 0 'Instead of fixing the symptom I fixed the cause.' 'instead-of, positive'

echo "MUST BLOCK (work handed over):"
t 2 'The badge is out of scope for this pass so I am leaving it for later.' 'out of scope'
t 2 'I am deferring the picker entries to a separate pass.' 'deferring'
t 2 'None blocks the hardware contract, so I have left them for a separate pass.' 'CANONICAL — the real 2026-08-14 failure'
t 2 'That redirect is unrelated to this change so I left it alone.' 'unrelated + left alone'
t 2 'Recorded it under known violation, fix on next touch.' 'next touch'
t 2 'It is pre-existing and I left it, since it is lower priority than the rest.' 'pre-existing + lower priority'
t 2 'I am flagging it rather than fixing it mid-refactor.' 'flagging rather than fixing'

exit "$fail"

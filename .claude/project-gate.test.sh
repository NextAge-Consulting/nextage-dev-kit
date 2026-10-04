#!/usr/bin/env bash
# Tests for project-gate.sh's mapping from a changed path to the suites covering it.
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=.claude/project-gate.sh
source .claude/project-gate.sh
fails=0
check() {
    local got
    got=$(suites_for "$1" | tr '\n' ' ')
    if [ "$got" = "$2" ]; then echo "ok   $3"; else echo "FAIL $3: got '$got', want '$2'"; fails=1; fi
}
check "_claude-project/skills/x/scripts/a.mjs" "_claude-project/skills/x/scripts/a.test.mjs _claude-project/skills/x/scripts/a.test.sh " "a module maps to the suites beside it"
check "_claude-project/hooks/h.sh" "_claude-project/hooks/h.test.sh " "a shell script maps to its .test.sh"
check "_claude-project/hooks/h.test.sh" "_claude-project/hooks/h.test.sh " "a changed suite runs itself"
check ".claude/hooks/git-guard.sh" "_claude-project/hooks/git-guard.test.sh " "a dogfood copy maps to its source's suite"
check ".claude/kit-gate/replay.mjs" ".claude/kit-gate/replay.test.mjs .claude/kit-gate/replay.test.sh " "a kit-only file keeps its own path"
check "_claude-project/stack-manifest.json" "tests/templates/check-stack.test.sh " "the stack manifest maps to the check-stack suite"
check "_claude-project/templates/scripts/check-stack.mjs" "tests/templates/check-stack.test.sh _claude-project/templates/scripts/check-stack.test.mjs _claude-project/templates/scripts/check-stack.test.sh " "a template script maps to its tests/templates suite"
check "project-documentation/x.md" "" "a doc maps to no suite"
exit "$fails"

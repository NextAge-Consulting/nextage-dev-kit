#!/usr/bin/env bash
# Regression suite for the branch↔issue link storage in issue_helpers.sh.
#
# These functions decide whether a GitHub issue gets closed and by which commit,
# so a silent regression here either strands an issue open or closes one nobody
# meant to touch. Everything below runs against a real throwaway git repo rather
# than a mock, because the storage IS git config — a mock would only assert that
# the mock works.
#
# The gh-dependent helpers (validate_issue, dump_issue_context, the project-board
# transitions) are deliberately not covered: they are thin wrappers over `gh`
# whose failure modes are network and auth, not logic.
set -uo pipefail
S="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/issue_helpers.sh"
fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

git init -q -b main "$tmp/repo"
cd "$tmp/repo" || exit 1
git config user.email t@example.com
git config user.name Tester

# shellcheck source=./issue_helpers.sh
source "$S"

t(){ # t <want> <got> <label>
  if [ "$1" = "$2" ]; then echo "  ✓ $3"; else echo "  ✗ FAIL (got '$2', want '$1') — $3"; fail=1; fi; }

echo "link storage:"
link_issue_to_branch 7 main
link_issue_to_branch 9 main
t "7 9" "$(read_branch_linked_issues main)" 'links accumulate in order'
link_issue_to_branch 7 main
t "7 9" "$(read_branch_linked_issues main)" 're-linking the same issue is idempotent'
t "" "$(read_branch_linked_issues never-used)" 'unknown branch reads empty'

echo "formatting:"
t "#7, #9" "$(format_issue_refs "$(read_branch_linked_issues main)")" 'refs render comma-separated'
t "Closes #7, #9" "$(closes_line_for_issues "$(read_branch_linked_issues main)")" 'closes line'
t "" "$(closes_line_for_issues "")" 'empty in, empty out — must not emit a bare "Closes"'
t "" "$(format_issue_refs "")" 'empty refs'

echo "migration across a branch creation:"
migrate_branch_linked_issues main feat/thing 2>/dev/null
t "7 9" "$(read_branch_linked_issues feat/thing)" 'links land on the new branch'
t "" "$(read_branch_linked_issues main)" 'source is CLEARED — a stale link must not re-close later'
migrate_branch_linked_issues main feat/thing 2>/dev/null
t "7 9" "$(read_branch_linked_issues feat/thing)" 'migrating an empty source is a no-op'
migrate_branch_linked_issues feat/thing feat/thing 2>/dev/null
t "7 9" "$(read_branch_linked_issues feat/thing)" 'migrating onto itself does not self-destruct'

echo "clearing:"
clear_branch_linked_issues feat/thing
t "" "$(read_branch_linked_issues feat/thing)" 'clear empties the list'
clear_branch_linked_issues feat/thing
t "" "$(read_branch_linked_issues feat/thing)" 'clearing twice is safe'

echo "set -e safety:"
# ship-main.sh runs under `set -e`. A helper returning non-zero on the empty
# path would abort the whole script mid-ship, after the commit and before the
# push. Each of these must return 0 with nothing linked.
# shellcheck source=./issue_helpers.sh
( set -e; source "$S"; closes_line_for_issues "" >/dev/null; \
  format_issue_refs "" >/dev/null; clear_branch_linked_issues nothing-here; \
  migrate_branch_linked_issues nothing-here also-nothing >/dev/null 2>&1; \
  report_parked_issue_links nothing-here 2>/dev/null ) \
  && t ok ok 'every empty path returns 0 under set -e' \
  || t ok "aborted" 'every empty path returns 0 under set -e'

echo "parked-link reporting:"
link_issue_to_branch 42 main
out=$(report_parked_issue_links main 2>&1)
case "$out" in *"#42"*) t ok ok 'names the parked issue';; *) t ok "no mention" 'names the parked issue';; esac
case "$out" in *"--unset branch.main.gitflow-issues"*) t ok ok 'prints the exact command to drop it';; *) t ok "missing" 'prints the exact command to drop it';; esac
clear_branch_linked_issues main
t "" "$(report_parked_issue_links main 2>&1)" 'silent when nothing is parked'

exit "$fail"

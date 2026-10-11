#!/usr/bin/env bash
# Regression suite for repo_kind.sh: each REPO_KIND answers the two questions the
# gitflow scripts ask, and combo answers yes to both.
set -uo pipefail
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
t(){ if [ "$1" = "$2" ]; then echo "  ✓ $3"; else echo "  ✗ FAIL (got '$2', want '$1') — $3"; fail=1; fi; }

cd "$tmp" || exit 1
mkdir -p .claude
# shellcheck source=_claude-project/skills/gitflow/scripts/repo_kind.sh
source "$D/repo_kind.sh"
ask(){ # ask <REPO_KIND or -> — echoes "<kind> <infra yes|no> <app yes|no>"
  if [ "$1" = "-" ]; then rm -f .claude/sync-substitutions.json; else printf '{"REPO_KIND":"%s"}\n' "$1" > .claude/sync-substitutions.json; fi
  local i=no a=no
  repo_holds_infra && i=yes
  repo_holds_app && a=yes
  echo "$(repo_kind) $i $a"
}

echo "repo_kind.sh:"
t "app no yes"   "$(ask app)"   'app holds an app, no infrastructure'
t "org yes no"   "$(ask org)"   'org holds infrastructure, no app'
t "combo yes yes" "$(ask combo)" 'combo holds both'
t "app no yes"   "$(ask '')"    'an empty REPO_KIND is app'
t "app no yes"   "$(ask -)"     'no settings file is app'

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"

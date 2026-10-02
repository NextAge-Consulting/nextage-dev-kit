#!/usr/bin/env bash
# Regression suite for rule-prose.sh — the set the rule-authoring guard and the
# gitflow rule-review gate both cover.
set -uo pipefail
# shellcheck source=rule-prose.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/rule-prose.sh"
fail=0
t(){ if is_rule_prose "$2"; then got=yes; else got=no; fi
     if [ "$got" = "$1" ]; then echo "  ✓ $3"; else echo "  ✗ FAIL (got $got, want $1) — $3"; fail=1; fi; }

echo "RULE PROSE:"
t yes "/r/.claude/rules/git.md"                      'rule'
t yes ".claude/rules/project/ui-inventory.md"        'project rule, relative'
t yes "/r/.claude/skills/ui-patterns/references/row-actions.md" 'pattern reference'
t yes "/r/.claude/commands/commit.md"                'command'
t yes "/r/.claude/agents/reviewer.md"                'agent'
t yes "/r/.claude/output-styles/house.md"            'output style'
t yes "/r/CLAUDE.md"                                 'root CLAUDE.md'
t yes "apps/web/CLAUDE.md"                           'nested CLAUDE.md'
t yes "_claude-project/rules/git.md"                 'kit source rule'
t yes "/r/_claude-project/templates/ui-inventory.md" 'kit inventory template'
t yes "_claude-maintainer/kit-maintainer.md"         'kit maintainer surface'

echo "NOT RULE PROSE:"
t no "/r/.claude/hooks/git-guard.sh"                 'hook script'
t no "/r/.claude/skills/gitflow/scripts/commit.sh"   'script inside a skill'
t no "/r/.claude/settings.json"                      'settings'
t no "/r/project-documentation/overview.md"          'human doc'
t no "/r/src/rules/pricing.md"                       'app dir named rules'
t no "/r/my.claude/rules/x.md"                       'no path boundary'
t no "/r/_claude-project/templates/dependency-policy.md" 'human-facing template'
t no ""                                              'empty path'
t yes 'C:\r\.claude\rules\x.md'                       'Windows backslash path'
t yes 'C:\r\CLAUDE.md'                                  'Windows backslash CLAUDE.md'

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"

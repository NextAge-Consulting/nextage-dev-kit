#!/bin/bash
# rule-prose.sh — the single definition of a rule-prose file: markdown that Claude
# loads as instructions. Sourced by rule-authoring-guard.sh and by the gitflow
# rule-review gate, so the hook and the commit gate always agree on what they cover.
#
#   is_rule_prose <path>   exit 0 when <path> (absolute or repo-relative) is rule prose
#
# Covered:
#   any CLAUDE.md
#   .claude/{rules,skills,commands,agents,output-styles}/**.md
#   the kit's sources: _claude-project/{rules,skills,commands,agents}/**.md,
#   _claude-project/templates/ui-inventory.md, _claude-maintainer/**.md

is_rule_prose() {
    local p="$1"
    [ -n "$p" ] || return 1
    case "${p##*/}" in
        CLAUDE.md) return 0 ;;
    esac
    case "$p" in
        *.md) ;;
        *) return 1 ;;
    esac
    # Anchor every pattern at a path boundary: leading `*/` for absolute paths, bare
    # for repo-relative ones.
    case "$p" in
        .claude/rules/*|*/.claude/rules/*|\
        .claude/skills/*|*/.claude/skills/*|\
        .claude/commands/*|*/.claude/commands/*|\
        .claude/agents/*|*/.claude/agents/*|\
        .claude/output-styles/*|*/.claude/output-styles/*|\
        _claude-project/rules/*|*/_claude-project/rules/*|\
        _claude-project/skills/*|*/_claude-project/skills/*|\
        _claude-project/commands/*|*/_claude-project/commands/*|\
        _claude-project/agents/*|*/_claude-project/agents/*|\
        _claude-project/templates/ui-inventory.md|*/_claude-project/templates/ui-inventory.md|\
        _claude-maintainer/*|*/_claude-maintainer/*)
            return 0 ;;
    esac
    return 1
}

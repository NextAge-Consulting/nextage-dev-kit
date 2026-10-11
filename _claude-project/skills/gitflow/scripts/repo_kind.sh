#!/bin/bash
# repo_kind.sh — what this repository holds. Sourced by the gitflow scripts.
#
#   app    application code: the app half of gitflow — /deploy on main cuts a release
#   org    an organization's Terraform: the infrastructure half — /open-pr plans the
#          changed roots, /deploy applies them and then merges
#   combo  both, in one repository: every command runs each half exactly as it runs in
#          its own kind, and which half /deploy runs follows the branch it runs on
#
# Read from REPO_KIND in .claude/sync-substitutions.json; empty is app. Commands ask
# repo_holds_infra and repo_holds_app, never the kind itself, so combo has no logic of
# its own and cannot drift from app or org.

repo_kind() {
    local kind
    kind=$(jq -r '.REPO_KIND // ""' .claude/sync-substitutions.json 2>/dev/null || true)
    echo "${kind:-app}"
}

# True for org and combo: Terraform here reaches main only through /deploy.
repo_holds_infra() {
    case "$(repo_kind)" in
        org|combo) return 0 ;;
    esac
    return 1
}

# True for app and combo: there is application code to merge and release.
repo_holds_app() {
    case "$(repo_kind)" in
        org) return 1 ;;
    esac
    return 0
}

#!/bin/bash
# install-kit.sh — Install/update the kit's global bootstrap into ~/.claude/.
#
# TWO TIERS. Defence by absence: a consumer machine never receives the sync
# machinery, so it cannot run it — no marker check, no guard to bypass.
#
#   (default)     CONSUMER  — mirrors `_claude-global/` → ~/.claude/
#                             Just the global `/work` bootstrap. `/work` must be
#                             invokable from the agents view BEFORE the session is
#                             inside any repo, so it cannot ship per-project.
#                             Everything else a project needs arrives via sync.
#
#   --maintainer  + MAINTAINER — also mirrors `_claude-maintainer/` → ~/.claude/
#                             sync-starter-kit.{sh,md} + kit-maintainer.md.
#                             ONLY for the one person who syncs the kit into
#                             projects. Every other dev receives kit updates when
#                             the maintainer syncs their project for them.
#
# kit-maintainer.md is inert unless `~/.claude/CLAUDE.md` imports it
# (`@kit-maintainer.md`) — that file is hand-maintained per machine and is NOT
# shipped by the kit. The separate `~/.claude/kitmaster` marker gates the
# block-kit-edit.sh hook. Both are needed for a real maintainer machine; see
# kit-maintainer.md.
#
# Must be run from inside the kit repo (detects via presence of _claude-global/).
#
# Idempotent — installs missing files, updates differing files, leaves identical ones alone.
# Per-file behavior: compare hashes; if different, show a brief note and apply.
#
# Exit codes: 0 = success, 1 = error.

set -e

MAINTAINER=0
while [[ $# -gt 0 ]]; do
    case $1 in
        --maintainer) MAINTAINER=1; shift ;;
        *) echo "install-kit.sh: unknown option: $1" >&2; exit 1 ;;
    esac
done

KIT_PATH="$PWD"
GLOBAL_DIR="$HOME/.claude"
SRC="$KIT_PATH/_claude-global"
MAINTAINER_SRC="$KIT_PATH/_claude-maintainer"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

error() { echo -e "${RED}ERROR: $1${NC}" >&2; exit 1; }
warn()  { echo -e "${YELLOW}$1${NC}"; }
info()  { echo -e "${BLUE}$1${NC}"; }
ok()    { echo -e "${GREEN}$1${NC}"; }

if [ ! -d "$SRC" ]; then
    error "$SRC does not exist. Kit structure is missing _claude-global/."
fi

# Hash helper (portable)
hash_file() {
    if command -v md5 >/dev/null 2>&1; then
        md5 -q "$1" 2>/dev/null || echo ""
    elif command -v md5sum >/dev/null 2>&1; then
        md5sum "$1" | awk '{print $1}'
    else
        echo ""
    fi
}

if [ "$MAINTAINER" -eq 1 ]; then
    TIER="CONSUMER + MAINTAINER"
    SOURCES="_claude-global/ + _claude-maintainer/"
else
    TIER="CONSUMER"
    SOURCES="_claude-global/"
fi

echo "=========================================="
echo "INSTALL KIT — $TIER"
echo "=========================================="
echo "Kit:    $KIT_PATH"
echo "Global: $GLOBAL_DIR"
echo "From:   $SOURCES"
echo ""

mkdir -p "$GLOBAL_DIR"

INSTALLED=0
UPDATED=0
UNCHANGED=0

# install_tree <src-root> — mirror every file under src-root into ~/.claude/,
# preserving relative layout. Idempotent: hash-compare, copy only on difference.
install_tree() {
    local src_root="$1"
    find "$src_root" -type f ! -name ".DS_Store" -print0 | while IFS= read -r -d '' src_file; do
        rel="${src_file#$src_root/}"
        dest_file="$GLOBAL_DIR/$rel"

        mkdir -p "$(dirname "$dest_file")"

        if [ ! -f "$dest_file" ]; then
            cp "$src_file" "$dest_file"
            case "$rel" in *.sh) chmod +x "$dest_file" ;; esac
            warn "  INSTALLED: $rel"
            INSTALLED=$((INSTALLED + 1))
        else
            src_hash=$(hash_file "$src_file")
            dest_hash=$(hash_file "$dest_file")
            if [ -n "$src_hash" ] && [ "$src_hash" != "$dest_hash" ]; then
                cp "$src_file" "$dest_file"
                case "$rel" in *.sh) chmod +x "$dest_file" ;; esac
                warn "  UPDATED: $rel"
                UPDATED=$((UPDATED + 1))
            else
                ok "  unchanged: $rel"
                UNCHANGED=$((UNCHANGED + 1))
            fi
        fi
    done
}

install_tree "$SRC"

if [ "$MAINTAINER" -eq 1 ]; then
    [ -d "$MAINTAINER_SRC" ] || error "$MAINTAINER_SRC does not exist. Kit structure is missing _claude-maintainer/."
    echo ""
    info "Maintainer surface:"
    install_tree "$MAINTAINER_SRC"
    echo ""
    # kit-maintainer.md is inert text without the import; the marker gates the hook.
    # Both are per-machine and deliberately NOT shipped — surface what's missing
    # rather than creating them, so a consumer machine can never self-promote.
    grep -q '@kit-maintainer.md' "$GLOBAL_DIR/CLAUDE.md" 2>/dev/null \
        || warn "  NOTE: ~/.claude/CLAUDE.md does not import @kit-maintainer.md — the maintainer rule will not load."
    [ -e "$GLOBAL_DIR/kitmaster" ] \
        || warn "  NOTE: ~/.claude/kitmaster missing — block-kit-edit.sh will still block kit edits. touch it to go inert."
fi

# Update config
cat > "$GLOBAL_DIR/starter-kit-config.json" << EOF
{
  "starterKitPath": "$KIT_PATH",
  "lastConfigured": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
info "Updated starter-kit-config.json"

# CPL version hint
CPL_VER_FILE="$KIT_PATH/_cpl/VERSION"
INSTALLED_CPL_VER="$HOME/.cpl-version"
if [ -f "$CPL_VER_FILE" ]; then
    REPO_VER=$(tr -d '[:space:]' < "$CPL_VER_FILE")
    if [ -f "$INSTALLED_CPL_VER" ]; then
        INST_VER=$(tr -d '[:space:]' < "$INSTALLED_CPL_VER")
        [ "$REPO_VER" != "$INST_VER" ] && warn "CPL: v${INST_VER} installed, v${REPO_VER} available. Run /install-cpl to update."
    else
        warn "CPL: not installed. v${REPO_VER} available. Run /install-cpl to install."
    fi
fi

echo ""
echo "=========================================="
echo "Done. (The counters above are per-file; summary below is approximate due to shell pipe scope.)"
echo "=========================================="

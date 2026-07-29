#!/bin/bash
# dev-server skill: stage a dev server in a new iTerm tab.
#
# Usage:
#   dev.sh                       List available dev* scripts at the resolved project root
#   dev.sh <app> [<app>...]      Stage dev server(s) in iTerm tabs in the current worktree
#   dev.sh <app> --main          Stage in PRIMARY repo (main), not the worktree
#   dev.sh --status              List listening processes on :3000-:3099 (pid, port, cwd, cmd)
#
# Behavior:
#   - Walks up from cwd to find the nearest package.json (project root).
#   - For each chosen app, detects the default port from apps/<app>/vite.config.ts
#     (or root vite.config.ts for flat layouts). Falls back to 3000.
#   - lsof check: if port free, uses it; if occupied, steps +10. Caps at 3 hops.
#   - Opens a new iTerm tab via osascript, cd's into the target dir, runs the
#     dev command. Tab title = "<app> @ <worktree-name> (:<port>)".
#
# Output:
#   For each staged app, prints "launched: <title>" + path + cmd.
#   On refusal, exits non-zero with a reason printed to stderr.
#
# Does NOT execute the dev command. Does NOT kill any process. --status surfaces only.

set -eo pipefail
# Note: do NOT rely on `inherit_errexit` here — bash 3.2 (macOS default) lacks
# it. Error propagation in this script uses explicit `if !` guards on the
# command substitutions whose failure actually matters
# (find_project_root, pick_port). Other `$(...)` captures either trail
# `|| true` (intentional best-effort) or invoke functions that cannot fail in
# a way that should abort. See `.claude/rules/bash-rules.md` §I, §III.

usage() {
  cat <<EOF
Usage:
  dev.sh                       List available dev scripts
  dev.sh <app> [<app>...]      Stage dev server(s) in iTerm tabs in current worktree
  dev.sh <app> --main          Stage in PRIMARY repo (main branch), not worktree
  dev.sh <app> --tunnel        Stage with Cloudflare tunnel (npm run dev:tunnel:<app>)
  dev.sh --status              List running dev servers (pid, port, cwd)
EOF
}

find_project_root() {
  local dir="${1:-$PWD}"
  while [ "$dir" != "/" ]; do
    if [ -f "$dir/package.json" ]; then
      echo "$dir"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  return 1
}

find_primary() {
  local cwd="$1"
  if [[ "$cwd" == */.claude/worktrees/* ]]; then
    echo "${cwd%%/.claude/worktrees/*}"
    return 0
  fi
  echo "$cwd"
}

detect_port() {
  local root="$1" app="$2" vite p
  # Two known patterns in consumer projects:
  #   1. Literal:  `port: 3010`
  #   2. Env-fallback: `Number(process.env.<ENV>) || 3010`
  #      (typically `const PORT = Number(process.env.<ENV>) || 3010; port: PORT`)
  #      where <ENV> is ANY env var name — commonly per-app in a monorepo
  #      (WEB_PORT, API_PORT), not the literal PORT.
  # Probe vite.config.ts at the per-app path first, then root for flat layouts.
  for vite in "$root/apps/$app/vite.config.ts" "$root/vite.config.ts"; do
    [ -f "$vite" ] || continue
    p="$(grep -oE 'port:[[:space:]]*[0-9]+' "$vite" | head -1 | grep -oE '[0-9]+' || true)"
    if [ -n "$p" ]; then
      echo "$p"
      return
    fi
    # `Number(process.env.<ENV>) || 3010` — capture the trailing default.
    p="$(grep -oE 'Number\(process\.env\.[A-Za-z_][A-Za-z0-9_]*\)[[:space:]]*\|\|[[:space:]]*[0-9]+' "$vite" | head -1 | grep -oE '[0-9]+$' || true)"
    if [ -n "$p" ]; then
      echo "$p"
      return
    fi
  done
  echo "3000"
}

detect_port_env() {
  local root="$1" app="$2" vite name
  # The env var the app's vite.config.ts reads to override its port. In a
  # monorepo each app typically has its own (WEB_PORT, API_PORT). Falls back
  # to PORT when the config declares no env-fallback (frameworks that honor
  # PORT out of the box).
  for vite in "$root/apps/$app/vite.config.ts" "$root/vite.config.ts"; do
    [ -f "$vite" ] || continue
    name="$(grep -oE 'Number\(process\.env\.[A-Za-z_][A-Za-z0-9_]*\)[[:space:]]*\|\|[[:space:]]*[0-9]+' "$vite" | head -1 | grep -oE 'process\.env\.[A-Za-z_][A-Za-z0-9_]*' | sed 's/process\.env\.//' || true)"
    if [ -n "$name" ]; then
      echo "$name"
      return
    fi
  done
  echo "PORT"
}

port_free() {
  ! lsof -iTCP:"$1" -sTCP:LISTEN -P -n -t >/dev/null 2>&1
}

pick_port() {
  # NOTE: each `local` must be its own statement because bash expands `$var`
  # references using OUTER scope values when they appear on the same `local`
  # line — `local a="$1" b="$a"` would leave b empty.
  local default="$1"
  local port="$default"
  local hop=0
  while [ $hop -lt 3 ]; do
    if port_free "$port"; then
      echo "$port"
      return 0
    fi
    port=$((port + 10))
    hop=$((hop + 1))
  done
  return 1
}

port_occupant() {
  local port="$1" pid cwd cmd
  pid="$(lsof -iTCP:"$port" -sTCP:LISTEN -P -n -t 2>/dev/null | head -1 || true)"
  [ -z "$pid" ] && return 1
  cwd="$(lsof -p "$pid" -d cwd -F n 2>/dev/null | grep '^n' | sed 's/^n//' | head -1 || true)"
  cmd="$(ps -p "$pid" -o command= 2>/dev/null | head -1 || true)"
  echo "pid=$pid cwd=${cwd:-?} cmd=${cmd:-?}"
}

list_dev_scripts() {
  local root="$1"
  if [ ! -f "$root/package.json" ]; then
    echo "no package.json at $root" >&2
    return 1
  fi
  if command -v jq >/dev/null 2>&1; then
    jq -r '.scripts // {} | to_entries[] | select(.key | startswith("dev")) | .key' "$root/package.json"
  else
    grep -oE '"dev[^"]*":[[:space:]]*"[^"]*"' "$root/package.json" \
      | grep -oE '"[^"]+":' \
      | tr -d '":'
  fi
}

cmd_status() {
  echo "Listening processes on :3000-:3099 (dev range):"
  echo ""
  local found=0 port pid cwd cmd
  for port in $(seq 3000 3099); do
    pid="$(lsof -iTCP:"$port" -sTCP:LISTEN -P -n -t 2>/dev/null | head -1 || true)"
    if [ -n "$pid" ]; then
      cwd="$(lsof -p "$pid" -d cwd -F n 2>/dev/null | grep '^n' | sed 's/^n//' | head -1 || true)"
      cmd="$(ps -p "$pid" -o command= 2>/dev/null | head -1 || true)"
      printf "  :%-5s  pid=%-7s\n" "$port" "$pid"
      printf "           cwd=%s\n" "${cwd:-?}"
      printf "           cmd=%s\n" "${cmd:-?}"
      found=$((found + 1))
    fi
  done
  if [ $found -eq 0 ]; then
    echo "  (none)"
  fi
}

stage_app() {
  local target_dir="$1" app="$2" port="$3" tunnel="$4" port_env="${5:-PORT}"
  local script_key="dev:$app"
  if [ "$app" = "dev" ]; then
    script_key="dev"
  fi
  if [ -n "$tunnel" ]; then
    script_key="dev:tunnel:$app"
  fi
  # An env var is the most reliable port override across the npm-script
  # nesting common in monorepos. Passing `-- --port N` through
  # `npm run dev:dealer -- --port N` → `npm run dev --prefix apps/dealer -- --port N`
  # is unreliable — npm's own flag parser consumes `--port` before it
  # reaches the inner npm and vite. An env var propagates cleanly through
  # any nesting level. `$port_env` is the var the app's vite.config.ts reads
  # (`port: Number(process.env.<ENV>) || <default>`) — per-app in a monorepo
  # (WEB_PORT, API_PORT); defaults to PORT, which TanStack Start / Nitro /
  # Next.js / Astro honor out of the box when the config adds no override.
  local cmd="$port_env=$port npm run $script_key"
  local title_suffix=""
  [ -n "$tunnel" ] && title_suffix=" [tunnel]"
  local title
  title="$app @ $(basename "$target_dir") (:$port)$title_suffix"

  # Tab title:
  # /dev tabs are spawned with the "DevServer" iTerm profile (NOT the user's
  # default profile). DevServer has `Allow Title Setting = true`, which lets
  # the inline `printf '\e]0;TITLE\a'` actually set session.name. The user's
  # default profile (e.g. CPL) keeps Allow Title Setting=false to prevent
  # Claude Code's startup OSC-0 width-probe from corrupting Claude's tab
  # title — a real concern verified empirically (Claude binary contains one
  # OSC 0 set-title for terminal width measurement, no OSC 22 push/pop).
  #
  # The DevServer profile JSON lives at:
  #   ~/Library/Application Support/iTerm2/DynamicProfiles/DevServer.json
  # See DEVSERVER-CHEATSHEET.md for one-time install steps.
  #
  # We use `printf` (not a `# comment` line) because zsh interactive shells
  # default INTERACTIVE_COMMENTS off — `# foo (:3010)` would parse as a
  # command and zsh's globbing would choke on `(:)`.
  local applescript
  applescript=$(cat <<APPLESCRIPT
tell application "iTerm2"
  tell current window
    create tab with profile "DevServer"
    tell current session
      write text "cd '$target_dir'"
      write text "printf '\\\\e]0;$title\\\\a'; $cmd"
    end tell
  end tell
end tell
APPLESCRIPT
)

  if ! osascript -e "$applescript" >/dev/null 2>&1; then
    echo "osascript failed — is iTerm2 running and frontmost?" >&2
    echo "intended command: $cmd" >&2
    echo "intended path:    $target_dir" >&2
    return 1
  fi

  echo "launched: $title"
  echo "  path: $target_dir"
  echo "  cmd:  $cmd"
}

# === MAIN ===

main_mode=""
status_mode=""
tunnel_mode=""
apps=()

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --main) main_mode=1 ;;
    --status) status_mode=1 ;;
    --tunnel) tunnel_mode=1 ;;
    --*) echo "unknown flag: $1" >&2; usage; exit 2 ;;
    *) apps+=("$1") ;;
  esac
  shift
done

if [ -n "$tunnel_mode" ] && [ -n "$main_mode" ]; then
  echo "--tunnel and --main are not compatible (tunnel ingress targets worktree ports)" >&2
  exit 2
fi

if [ -n "$status_mode" ]; then
  cmd_status
  exit 0
fi

cwd="$PWD"
if ! worktree_root="$(find_project_root "$cwd")"; then
  echo "no package.json found walking up from $cwd" >&2
  exit 3
fi

if [ -n "$main_mode" ]; then
  target_dir="$(find_primary "$worktree_root")"
else
  target_dir="$worktree_root"
fi

if [ ${#apps[@]} -eq 0 ]; then
  echo "Available dev scripts at $worktree_root:"
  list_dev_scripts "$worktree_root" | sed 's/^/  /'
  echo ""
  echo "Invoke: dev.sh <app> [<app>...] [--main]"
  exit 0
fi

if ! available_scripts="$(list_dev_scripts "$worktree_root")"; then
  echo "failed to enumerate dev scripts in $worktree_root/package.json" >&2
  exit 4
fi
for app in "${apps[@]}"; do
  script_key="dev:$app"
  [ "$app" = "dev" ] && script_key="dev"
  [ -n "$tunnel_mode" ] && script_key="dev:tunnel:$app"
  if ! echo "$available_scripts" | grep -qx "$script_key"; then
    echo "no script '$script_key' in $worktree_root/package.json" >&2
    echo "available:" >&2
    echo "$available_scripts" | sed 's/^/  /' >&2
    exit 4
  fi
done

for app in "${apps[@]}"; do
  default_port="$(detect_port "$worktree_root" "$app")"
  port_env="$(detect_port_env "$worktree_root" "$app")"
  if ! port="$(pick_port "$default_port")"; then
    echo "no free port found stepping +10 from :$default_port (3 hops); refusing" >&2
    echo "occupants:" >&2
    for hop in 0 10 20; do
      occupant="$(port_occupant "$((default_port + hop))" 2>/dev/null || true)"
      echo "  :$((default_port + hop)) ${occupant:-?}" >&2
    done
    echo "stop one and retry, or run --status" >&2
    exit 5
  fi
  if [ "$port" != "$default_port" ]; then
    echo "port :$default_port occupied → using :$port (auto-bumped +$((port - default_port)))"
    occupant="$(port_occupant "$default_port" 2>/dev/null || true)"
    [ -n "$occupant" ] && echo "  :$default_port occupant: $occupant"
  fi
  stage_app "$target_dir" "$app" "$port" "$tunnel_mode" "$port_env"
done

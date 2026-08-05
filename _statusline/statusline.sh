#!/bin/bash
# Custom Claude Code statusline
# Line 1: Core info (directory, branch, version, model)
# Line 2: Native Claude metrics (context, cost, duration, lines changed)

# ==========================================
# SETTINGS - ADJUST THESE AS NEEDED
# ==========================================
# Fudge factor (in tokens) to add to current_usage to approximate actual context window
# Accounts for system prompt, tools, memory files, etc. not captured in current_usage
# I believe this is actually just the Autocompact Buffer
FUDGE_FACTOR=33000

# Debug mode: Set to 1 to write input JSON to debug file
# Toggle manually: DEBUG_STATUSLINE=0 (off) or DEBUG_STATUSLINE=1 (on)
DEBUG_STATUSLINE=0
DEBUG_FILE="$HOME/.claude/statusline-input.json"

input=$(cat)

# Write debug output if enabled
if [ "$DEBUG_STATUSLINE" -eq 1 ]; then
  echo "$input" | jq '.' > "$DEBUG_FILE" 2>/dev/null
fi

# ---- Color helpers ----
use_color=1
[ -n "$NO_COLOR" ] && use_color=0

green() { if [ "$use_color" -eq 1 ]; then printf '\033[38;5;158m'; fi; }
yellow() { if [ "$use_color" -eq 1 ]; then printf '\033[38;5;215m'; fi; }
red() { if [ "$use_color" -eq 1 ]; then printf '\033[38;5;203m'; fi; }
cyan() { if [ "$use_color" -eq 1 ]; then printf '\033[38;5;117m'; fi; }
gray() { if [ "$use_color" -eq 1 ]; then printf '\033[38;5;249m'; fi; }
rst() { if [ "$use_color" -eq 1 ]; then printf '\033[0m'; fi; }

# ---- Check for jq ----
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq not installed"
  exit 1
fi

# ==========================================
# LINE 1: CORE INFO
# ==========================================

# Directory
current_dir=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // "N/A"' | sed "s|^$HOME|~|g")

# Git branch
git_branch=$(git branch --show-current 2>/dev/null || echo "no-git")

# CC version
version=$(echo "$input" | jq -r '.version // "N/A"')

# Model
model_display=$(echo "$input" | jq -r '.model.display_name // "N/A"')

# Width-aware truncation. Claude Code reserves a fixed visual-row budget for
# the statusline; if line 1 wraps to two visual rows (long path + long branch),
# line 2 gets squeezed out. Read terminal columns from the input JSON and
# truncate path/branch when the static line 1 would overflow. Version + model
# stay unmodified — they're short and informational. Each emoji renders as
# 2 cols in monospace terminals; bash ${#var} counts characters not display
# cols, so we account for the emoji+space overhead manually.
# Claude Code reports terminal columns, but the statusline render area is narrower
# than the full terminal: sidebar gutter + right-edge padding eat ~8 cols. Without
# a safety buffer, my "exactly fits" line 1 still gets clipped by CC's own
# truncation (visible as "Opus 4.7 (1M conte…" tail). Empirical buffer = 8.
columns=$(echo "$input" | jq -r '.columns // 120')
columns=$(( columns - 8 ))
[ "$columns" -lt 40 ] && columns=40
overhead=18  # 4 emojis @ 2 cols + 4 trailing spaces + 3 double-space separators
overflow=$(( overhead + ${#current_dir} + ${#git_branch} + ${#version} + ${#model_display} - columns ))

if [ "$overflow" -gt 0 ]; then
    # First reclaim: collapse path to ".../<basename>" when path has segments.
    case "$current_dir" in
        */*)
            short_dir=".../${current_dir##*/}"
            saved=$(( ${#current_dir} - ${#short_dir} ))
            if [ "$saved" -gt 0 ]; then
                current_dir="$short_dir"
                overflow=$(( overflow - saved ))
            fi
            ;;
    esac
    # Second reclaim: truncate branch with trailing ellipsis if still overflowing.
    if [ "$overflow" -gt 0 ] && [ "${#git_branch}" -gt 8 ]; then
        keep=$(( ${#git_branch} - overflow - 1 ))
        [ "$keep" -lt 8 ] && keep=8
        git_branch="${git_branch:0:$keep}…"
    fi
fi

printf '📁 %s%s%s  🌿 %s  📟 %s  🤖 %s\n' \
  "$(cyan)" "$current_dir" "$(rst)" "$git_branch" "$version" "$model_display"

# ==========================================
# LINE 2: NATIVE CLAUDE METRICS
# ==========================================

# Token counts - use current_usage to approximate context window
window_size=$(echo "$input" | jq -r '.context_window.context_window_size // 200000')
usage=$(echo "$input" | jq '.context_window.current_usage')

if [ "$usage" != "null" ] && [ "$window_size" -gt 0 ]; then
  current_tokens=$(echo "$usage" | jq '.input_tokens + .cache_creation_input_tokens + .cache_read_input_tokens')
else
  current_tokens=0
fi

# Always add fudge factor for system overhead (memory files, tools, etc.)
current_tokens=$((current_tokens + FUDGE_FACTOR))
pct=$(( current_tokens * 100 / window_size ))

# Format tokens (K for thousands, m for millions)
current_k=$((current_tokens / 1000))
if [ "$window_size" -ge 1000000 ]; then
  window_label="$((window_size / 1000000))m"
else
  window_label="$((window_size / 1000))K"
fi

# Color based on context percentage
if [ "$pct" -gt 90 ]; then
  pct_color=$(red)
elif [ "$pct" -gt 75 ]; then
  pct_color=$(yellow)
else
  pct_color=$(green)
fi

# Duration (convert ms to hr + min)
duration_ms=$(echo "$input" | jq -r '.cost.total_duration_ms // 0')
duration_min=$((duration_ms / 60000))
duration_hr=$((duration_min / 60))
duration_min_remainder=$((duration_min % 60))

# Lines changed
lines_added=$(echo "$input" | jq -r '.cost.total_lines_added // 0')
lines_removed=$(echo "$input" | jq -r '.cost.total_lines_removed // 0')

# Rate limits (Claude.ai Pro/Max only - absent for API key users)
five_h_pct=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
five_h_resets=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
seven_d_pct=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')
seven_d_resets=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty')
now_epoch=$(date +%s)

# Format seconds remaining as Xh Ym
fmt_remaining() {
  local secs=$(( $1 - now_epoch ))
  [ "$secs" -le 0 ] && return
  local days=$(( secs / 86400 ))
  local hrs=$(( (secs % 86400) / 3600 ))
  local mins=$(( (secs % 3600) / 60 ))
  if [ "$days" -gt 0 ]; then
    printf ' (%dd %dh)' "$days" "$hrs"
  elif [ "$hrs" -gt 0 ]; then
    printf ' (%dh %dm)' "$hrs" "$mins"
  else
    printf ' (%dm)' "$mins"
  fi
}

# Projected full-session usage (integer math, no floats)
# projected = usage_pct * window_secs / time_used
rl_projected() {
  local usage_pct=$1 remaining_secs=$2 window_secs=$3
  local time_used=$(( window_secs - remaining_secs ))
  [ "$time_used" -lt 60 ] && time_used=60
  echo $(( usage_pct * window_secs / time_used ))
}

rl_color() {
  local projected=$1
  if [ "$projected" -gt 95 ]; then printf '%s' "$(red)"
  elif [ "$projected" -gt 75 ]; then printf '%s' "$(yellow)"
  else printf '%s' "$(green)"; fi
}

rate_limits_str=""
if [ -n "$five_h_pct" ]; then
  five_h_int=$(printf '%.0f' "$five_h_pct")
  five_h_remaining=$(( five_h_resets - now_epoch ))
  [ "$five_h_remaining" -lt 0 ] && five_h_remaining=0
  rl5_proj=$(rl_projected "$five_h_int" "$five_h_remaining" 18000)
  rl5_color=$(rl_color "$rl5_proj")
  rl5_reset=""
  [ -n "$five_h_resets" ] && [ "$rl5_proj" -gt 75 ] && rl5_reset=$(fmt_remaining "$five_h_resets")
  rate_limits_str="  ⚡ 5h=${rl5_color}${five_h_int}%${rl5_reset}$(rst)"
fi
if [ -n "$seven_d_pct" ]; then
  seven_d_int=$(printf '%.0f' "$seven_d_pct")
  seven_d_remaining=$(( seven_d_resets - now_epoch ))
  [ "$seven_d_remaining" -lt 0 ] && seven_d_remaining=0
  rl7_proj=$(rl_projected "$seven_d_int" "$seven_d_remaining" 604800)
  rl7_color=$(rl_color "$rl7_proj")
  rl7_reset=""
  [ -n "$seven_d_resets" ] && [ "$rl7_proj" -gt 75 ] && rl7_reset=$(fmt_remaining "$seven_d_resets")
  rate_limits_str="${rate_limits_str} 7d=${rl7_color}${seven_d_int}%${rl7_reset}$(rst)"
fi

printf '📊 %dK/%s=%s%d%%%s%s ⏱️ %dh %dm 📝 +%d -%d\n' \
  "$current_k" "$window_label" "$pct_color" "$pct" "$(rst)" \
  "$rate_limits_str" "$duration_hr" "$duration_min_remainder" "$lines_added" "$lines_removed"

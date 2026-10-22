#!/usr/bin/env bash
# Regression suite for dev.sh's iTerm2 launch: the text typed into the new tab.
#
# `osascript` is a stub that records the AppleScript it is handed, and tmux is kept off
# PATH, so the launch falls to the iTerm2 backend on any machine.
set -uo pipefail
S="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dev.sh"
fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }

mkdir -p "$tmp/bin" "$tmp/proj"
cat > "$tmp/bin/osascript" <<'EOF'
#!/bin/sh
printf '%s\n' "$2" > "$OSA_LOG"
EOF
chmod +x "$tmp/bin/osascript"
ln -s "$(command -v jq)" "$tmp/bin/jq"
export OSA_LOG="$tmp/osa.log"

printf '{"name":"proj","scripts":{"dev:web":"vite"}}\n' > "$tmp/proj/package.json"

out=$(cd "$tmp/proj" && env -u TMUX PATH="$tmp/bin:/usr/bin:/bin:/usr/sbin" bash "$S" web 2>&1); rc=$?
[ "$rc" -eq 0 ] && grep -q "new iTerm2 tab" <<<"$out" && ok "launch falls to the iTerm2 backend" || bad "launch (rc=$rc): $out"

lines=$(grep -c 'write text' "$OSA_LOG")
[ "$lines" = "1" ] && ok "the tab gets one line" || bad "write text lines: $lines"

line=$(grep 'write text' "$OSA_LOG")
case "$line" in
    *"write text \"cd '$tmp/proj' && printf "*"&& PORT="*" npm run dev:web\"") ok "cd, title and command are joined by &&, so a failed cd runs nothing" ;;
    *) bad "tab line: $line" ;;
esac

# The line the tab runs: with a folder that does not exist, nothing after the cd runs.
cmdline=$(sed -n 's/^ *write text "\(.*\)"$/\1/p' "$OSA_LOG" | sed "s#cd '$tmp/proj'#cd '$tmp/missing'#; s#npm run dev:web#echo RAN#")
ran=$(bash -c "$cmdline" 2>/dev/null)
[ -z "$ran" ] && ok "a cd that fails stops the command" || bad "command ran after a failed cd: $ran"

exit "$fail"

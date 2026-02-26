#!/bin/bash
# Example Claude Code status line script.
# Combines the 5h context bar and 7d burn-rate bar into a single line.
#
# Reads the Claude Code status line JSON from STDIN and calls
# claude-usage-7d.sh for the 7-day burn rate (cached by default).
#
# Output:  🧠 Opus │ 📁 my_project │ 5h ▓░░░░ 🟢 │ 7d ▓▓░░░ 🟢
#
# Installation:
#   1. Copy to ~/.claude/statusline.sh (or anywhere you like)
#   2. chmod +x ~/.claude/statusline.sh
#   3. Edit the WEEKEND_DAYS variable below to match your locale
#   4. Add to ~/.claude/settings.json:
#      { "statusLine": { "type": "command", "command": "~/.claude/statusline.sh" } }

set -euo pipefail

# --- Configuration ---
# Set weekend days for the 7d burn-rate calculation.
# 1=Mon … 7=Sun.  Examples: "5,6" (Israel), "6,7" (most countries), "" (none).
WEEKEND_DAYS="5,6"

input=$(cat)

# --- Model name and project folder ---
MODEL=$(echo "$input" | jq -r '.model.display_name')
DIR=$(echo "$input" | jq -r '.workspace.project_dir' | xargs basename)

# --- 5h context bar (inline, from stdin data) ---
PCT=$(echo "$input" | jq -r '.context_window.used_percentage // 0' | cut -d. -f1)

filled_5h=$(( (PCT + 10) / 20 ))
[ "$filled_5h" -gt 5 ] && filled_5h=5
bar_5h=""
for i in 1 2 3 4 5; do
  if [ "$i" -le "$filled_5h" ]; then
    bar_5h="${bar_5h}▓"
  else
    bar_5h="${bar_5h}░"
  fi
done

if [ "$PCT" -ge 90 ]; then
  icon_5h="🔴"
elif [ "$PCT" -ge 50 ]; then
  icon_5h="🟡"
else
  icon_5h="🟢"
fi

# --- 7d burn-rate bar (from cached CLI script) ---
bar_7d=$(claude-usage-7d.sh -b -w "$WEEKEND_DAYS" 2>/dev/null || echo "7d ????? ⚪")

printf "🧠 %s │ 📁 %s │ 5h %s %s │ %s\n" "$MODEL" "$DIR" "$bar_5h" "$icon_5h" "$bar_7d"

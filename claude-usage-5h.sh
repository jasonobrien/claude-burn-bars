#!/bin/bash
# Claude Code context-window status bar.
# Reads the Claude Code status line JSON from STDIN and renders
# a compact 5-slot bar for the context window (5h) usage.

set -euo pipefail

input=$(cat)

PCT=$(echo "$input" | jq -r '.context_window.used_percentage // 0' | cut -d. -f1)

# Build a 5-slot progress bar: each slot = 20%.
filled=$(( (PCT + 10) / 20 ))
[ "$filled" -gt 5 ] && filled=5
bar=""
for i in 1 2 3 4 5; do
  if [ "$i" -le "$filled" ]; then
    bar="${bar}▓"
  else
    bar="${bar}░"
  fi
done

# Icon: green <50%, yellow 50-90%, red 90%+
if [ "$PCT" -ge 90 ]; then
  icon="🔴"
elif [ "$PCT" -ge 50 ]; then
  icon="🟡"
else
  icon="🟢"
fi

printf "5h %s %s\n" "$bar" "$icon"

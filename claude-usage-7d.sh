#!/bin/bash
# claude-usage-7d.sh — Claude Code 7-day burn-rate calculator.
#
# Fetches 7-day usage from the Anthropic API, calculates the average
# burn rate per work day, and projects whether you'll exceed the limit
# before the rolling window resets.
#
# Requires: jq, curl, bc, and macOS Keychain with Claude Code credentials.
#
# Usage:
#   claude-usage-7d.sh [OPTIONS]
#
# Options:
#   -b, --bar                  Compact status-bar output: "7d ▓░░░░ 🟢"
#   -w, --weekend-days DAYS    Comma-separated weekend day numbers to skip
#                              (1=Mon … 7=Sun). Default: none (all days count).
#                              Example: -w 5,6 for Israel (Fri+Sat)
#                              Example: -w 6,7 for most countries (Sat+Sun)
#   -t, --ttl SECONDS          Cache TTL in seconds. Default: 3600 (1 hour).
#                              Pass -t "" or --ttl="" to disable caching.
#   -c, --cache-dir DIR        Cache directory. Default: $XDG_CACHE_HOME/claude-usage
#                              or ~/.cache/claude-usage.
#   -h, --help                 Show this help message and exit.

set -euo pipefail

# --- Defaults ---
BAR_MODE=false
WEEKEND_DAYS=""
CACHE_TTL=3600
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/claude-usage"
CACHE_TTL_SET=false

# --- CLI parsing ---
show_help() {
  cat <<'HELP'
claude-usage-7d.sh — Claude Code 7-day burn-rate calculator.

Fetches 7-day usage from the Anthropic API, calculates the average
burn rate per work day, and projects whether you'll exceed the limit
before the rolling window resets.

Requires: jq, curl, bc, and macOS Keychain with Claude Code credentials.

Usage:
  claude-usage-7d.sh [OPTIONS]

Options:
  -b, --bar                  Compact status-bar output: "7d ▓░░░░ 🟢"
  -w, --weekend-days DAYS    Comma-separated weekend day numbers to skip
                             (1=Mon … 7=Sun). Default: none (all days count).
                             Example: -w 5,6 for Israel (Fri+Sat)
                             Example: -w 6,7 for most countries (Sat+Sun)
  -t, --ttl SECONDS          Cache TTL in seconds. Default: 3600 (1 hour).
                             Pass -t "" or --ttl="" to disable caching.
  -c, --cache-dir DIR        Cache directory.
                             Default: $XDG_CACHE_HOME/claude-usage
                             or ~/.cache/claude-usage.
  -h, --help                 Show this help message and exit.
HELP
  exit 0
}

args=("$@")
i=0
while [ $i -lt ${#args[@]} ]; do
  arg="${args[$i]}"
  # Helper: grab the next positional value for flags that take one.
  next_val() {
    if [[ "$arg" == *=* ]]; then
      echo "${arg#*=}"
    else
      i=$((i + 1))
      echo "${args[$i]}"
    fi
  }
  case "$arg" in
    -h|--help) show_help ;;
    -b|--bar)  BAR_MODE=true ;;
    -w|--weekend-days|-w=*|--weekend-days=*) WEEKEND_DAYS=$(next_val) ;;
    -t|--ttl|-t=*|--ttl=*)                   CACHE_TTL=$(next_val); CACHE_TTL_SET=true ;;
    -c|--cache-dir|-c=*|--cache-dir=*)       CACHE_DIR=$(next_val) ;;
  esac
  i=$((i + 1))
done

# Normalize comma-separated weekend days → space-separated.
WEEKEND_DAYS="${WEEKEND_DAYS//,/ }"

# --- Caching ---
# When TTL is set to empty string, caching is disabled.
# Otherwise the API response is cached to avoid redundant requests.

CACHE_FILE="$CACHE_DIR/7d-response.json"

fetch_from_api() {
  local token
  token=$(
    security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null \
      | jq -r '.claudeAiOauth.accessToken'
  )

  if [ -z "$token" ] || [ "$token" = "null" ]; then
    echo "Error: could not retrieve Claude Code access token from Keychain" >&2
    exit 1
  fi

  curl -s -f \
    -H "Accept: application/json" \
    -H "Content-Type: application/json" \
    -H "User-Agent: claude-code/2.0.32" \
    -H "Authorization: Bearer $token" \
    -H "anthropic-beta: oauth-2025-04-20" \
    "https://api.anthropic.com/api/oauth/usage" \
  || { echo "Error: API request failed" >&2; exit 1; }
}

cache_is_stale() {
  [ ! -f "$CACHE_FILE" ] && return 0
  local age=$(( $(date +%s) - $(stat -f %m "$CACHE_FILE" 2>/dev/null || echo 0) ))
  [ "$age" -gt "$CACHE_TTL" ]
}

if [ -z "$CACHE_TTL" ]; then
  # Caching disabled — always fetch live.
  response=$(fetch_from_api)
else
  if cache_is_stale; then
    mkdir -p "$CACHE_DIR"
    response=$(fetch_from_api)
    echo "$response" > "$CACHE_FILE"
  else
    response=$(cat "$CACHE_FILE")
  fi
fi

# --- Parse API response ---

utilization=$(echo "$response" | jq -r '.seven_day.utilization')
resets_at=$(echo "$response" | jq -r '.seven_day.resets_at')

if [ -z "$utilization" ] || [ "$utilization" = "null" ]; then
  echo "Error: could not parse utilization from API response" >&2
  exit 1
fi

# --- Date helpers (BSD date on macOS) ---

is_weekend() {
  [ -z "$WEEKEND_DAYS" ] && return 1
  local dow
  dow=$(date -j -f "%Y-%m-%d" "$1" "+%u")
  for wd in $WEEKEND_DAYS; do
    [ "$dow" = "$wd" ] && return 0
  done
  return 1
}

# Count work days in a half-open range [start, end).
count_work_days() {
  local cur="$1" end="$2" count=0
  while [ "$cur" != "$end" ]; do
    is_weekend "$cur" || count=$((count + 1))
    cur=$(date -j -v+1d -f "%Y-%m-%d" "$cur" "+%Y-%m-%d")
  done
  echo "$count"
}

# --- Compute dates ---

# resets_at is an ISO timestamp like "2026-02-26T…"; extract the date part.
reset_date=${resets_at%%T*}
window_start=$(date -j -v-7d -f "%Y-%m-%d" "$reset_date" "+%Y-%m-%d")
today=$(date "+%Y-%m-%d")

# --- Count work days ---

elapsed_work_days=$(count_work_days "$window_start" "$today")
remaining_work_days=$(count_work_days "$today" "$reset_date")

# --- Calculate rates ---

if [ "$elapsed_work_days" -gt 0 ]; then
  avg_per_day=$(echo "scale=1; $utilization / $elapsed_work_days" | bc)
else
  avg_per_day="N/A"
fi

remaining_budget=$(echo "scale=1; 100 - $utilization" | bc)

if [ "$avg_per_day" != "N/A" ]; then
  projected_remaining=$(echo "scale=1; $remaining_work_days * $avg_per_day" | bc)
else
  projected_remaining="N/A"
fi

# --- Determine warning status ---

is_over=false
if [ "$projected_remaining" != "N/A" ]; then
  [ "$(echo "$projected_remaining > $remaining_budget" | bc)" -eq 1 ] && is_over=true
fi

# --- Output ---

if [ "$BAR_MODE" = true ]; then
  # Build a 5-slot progress bar: each slot = 20%.
  # ▓ = filled, ░ = empty
  filled=$(echo "($utilization + 10) / 20" | bc)  # round to nearest slot
  [ "$filled" -gt 5 ] && filled=5
  bar=""
  for i in 1 2 3 4 5; do
    if [ "$i" -le "$filled" ]; then
      bar="${bar}▓"
    else
      bar="${bar}░"
    fi
  done

  if [ "$is_over" = true ]; then
    icon="🔴"
  else
    icon="🟢"
  fi

  printf "7d %s %s\n" "$bar" "$icon"
else
  printf "7-day utilization:   %s%%\n" "$utilization"
  printf "Window:              %s → %s\n" "$window_start" "$reset_date"
  printf "Work days elapsed:   %s\n" "$elapsed_work_days"
  printf "Avg usage/work day:  %s%%\n" "$avg_per_day"
  printf "Remaining work days: %s\n" "$remaining_work_days"
  printf "Remaining budget:    %s%%\n" "$remaining_budget"
  printf "Projected remaining: %s%%\n" "$projected_remaining"

  if [ "$is_over" = true ]; then
    projected_total=$(echo "scale=1; $utilization + $projected_remaining" | bc)
    printf "\n⚠ WARNING: Projected total usage %.1f%% exceeds 100%% limit by end of window!\n" "$projected_total"
  fi
fi

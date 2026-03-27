#!/bin/bash
# claude-usage-7d.sh — Claude Code 7-day burn-rate calculator.
#
# Fetches 7-day usage from the Anthropic API, calculates the average
# burn rate per work day, and projects whether you'll exceed the limit
# before the rolling window resets.
#
# Requires: jq, curl, bc, and either macOS Keychain or ~/.claude/.credentials.json (Linux).
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

Requires: jq, curl, bc, and either macOS Keychain or ~/.claude/.credentials.json (Linux).

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
  if [[ "$(uname)" == "Darwin" ]]; then
    token=$(
      security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null \
        | jq -r '.claudeAiOauth.accessToken'
    )
  else
    token=$(
      jq -r '.claudeAiOauth.accessToken' "$HOME/.claude/.credentials.json" 2>/dev/null
    )
  fi

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
  local mtime
  if [[ "$(uname)" == "Darwin" ]]; then
    mtime=$(stat -f %m "$CACHE_FILE" 2>/dev/null || echo 0)
  else
    mtime=$(stat -c %Y "$CACHE_FILE" 2>/dev/null || echo 0)
  fi
  local age=$(( $(date +%s) - mtime ))
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

# --- Epoch helpers ---

parse_iso_epoch() {
  # Parse an ISO 8601 timestamp (with optional fractional seconds and tz offset) to Unix epoch.
  local ts="$1"
  if [[ "$(uname)" == "Darwin" ]]; then
    # Strip fractional seconds; convert colon in tz offset (+HH:MM → +HHMM) for BSD date.
    local ts_clean
    ts_clean=$(printf '%s' "$ts" \
      | sed 's/\.[0-9]*//' \
      | sed 's/\([+-][0-9][0-9]\):\([0-9][0-9]\)$/\1\2/')
    date -j -f "%Y-%m-%dT%H:%M:%S%z" "$ts_clean" "+%s"
  else
    date -d "$ts" "+%s"
  fi
}

epoch_to_local_date() {
  # Convert a Unix epoch to a YYYY-MM-DD string in the local timezone.
  if [[ "$(uname)" == "Darwin" ]]; then
    date -j -r "$1" "+%Y-%m-%d"
  else
    date -d "@$1" "+%Y-%m-%d"
  fi
}

start_of_day_epoch() {
  # Return the epoch for midnight (local time) of the day containing epoch $1.
  local d
  d=$(epoch_to_local_date "$1")
  if [[ "$(uname)" == "Darwin" ]]; then
    date -j -f "%Y-%m-%d" "$d" "+%s"
  else
    date -d "$d" "+%s"
  fi
}

is_weekend_epoch() {
  # Return 0 (true) if the local calendar day of epoch $1 is a configured weekend day.
  [ -z "$WEEKEND_DAYS" ] && return 1
  local dow
  if [[ "$(uname)" == "Darwin" ]]; then
    dow=$(date -j -r "$1" "+%u")
  else
    dow=$(date -d "@$1" "+%u")
  fi
  for wd in $WEEKEND_DAYS; do
    [ "$dow" = "$wd" ] && return 0
  done
  return 1
}

# Count work seconds in [start_epoch, end_epoch), iterating local calendar days.
# Partial days at each boundary are counted proportionally.
count_work_seconds() {
  local start="$1" end="$2"
  [ "$start" -ge "$end" ] && echo 0 && return
  local total=0 cur next day_start day_end
  cur=$(start_of_day_epoch "$start")
  while [ "$cur" -lt "$end" ]; do
    next=$(( cur + 86400 ))
    day_start=$(( cur > start ? cur : start ))
    day_end=$(( next < end ? next : end ))
    if ! is_weekend_epoch "$cur"; then
      total=$(( total + day_end - day_start ))
    fi
    cur=$next
  done
  echo "$total"
}

# --- Compute timestamps ---

reset_epoch=$(parse_iso_epoch "$resets_at")
now_epoch=$(date "+%s")
window_start_epoch=$(( reset_epoch - 7 * 24 * 3600 ))

# Local date strings for display only.
window_start_display=$(epoch_to_local_date "$window_start_epoch")
reset_display=$(epoch_to_local_date "$reset_epoch")

# --- Count work time ---

elapsed_work_secs=$(count_work_seconds "$window_start_epoch" "$now_epoch")
remaining_work_secs=$(count_work_seconds "$now_epoch" "$reset_epoch")

# --- Calculate rates ---

# Express elapsed/remaining as fractional work days (86400 s = 1 day) for display.
elapsed_work_days=$(echo "scale=1; $elapsed_work_secs / 86400" | bc)
remaining_work_days=$(echo "scale=1; $remaining_work_secs / 86400" | bc)

# Compute avg and projection directly from seconds to avoid divide-by-zero when
# elapsed_work_days rounds down to 0 (e.g. only a few hours into the window).
if [ "$elapsed_work_secs" -gt 0 ]; then
  avg_per_day=$(echo "scale=2; $utilization * 86400 / $elapsed_work_secs" | bc)
  projected_remaining=$(echo "scale=1; $remaining_work_secs * $avg_per_day / 86400" | bc)
else
  avg_per_day="N/A"
  projected_remaining="N/A"
fi

remaining_budget=$(echo "scale=1; 100 - $utilization" | bc)

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
  remaining_h=$(( remaining_work_secs / 3600 ))
  remaining_m=$(( (remaining_work_secs % 3600) / 60 ))
  printf "7-day utilization:    %s%%\n" "$utilization"
  printf "Window:               %s → %s\n" "$window_start_display" "$reset_display"
  printf "Work time elapsed:    %s days\n" "$elapsed_work_days"
  printf "Avg usage/work day:   %s%%\n" "$avg_per_day"
  printf "Work time remaining:  %s days (%dh %02dm)\n" "$remaining_work_days" "$remaining_h" "$remaining_m"
  printf "Remaining budget:     %s%%\n" "$remaining_budget"
  printf "Projected remaining:  %s%%\n" "$projected_remaining"

  if [ "$is_over" = true ]; then
    projected_total=$(echo "scale=1; $utilization + $projected_remaining" | bc)
    printf "\n⚠ WARNING: Projected total usage %.1f%% exceeds 100%% limit by end of window!\n" "$projected_total"
  fi
fi

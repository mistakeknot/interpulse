#!/usr/bin/env bash
# Shared library for interpulse hooks.
#
# Provides:
#   _ip_session_id     — extract session_id from stdin JSON
#   _ip_state_file     — path to session state file
#   _ip_read_state     — read state JSON (or default)
#   _ip_write_state    — write state JSON

[[ -n "${_LIB_INTERPULSE_LOADED:-}" ]] && return 0
_LIB_INTERPULSE_LOADED=1

_ip_session_id() {
  echo "$1" | jq -r '.session_id // empty' 2>/dev/null
}

_ip_state_file() {
  local sid="$1"
  echo "/tmp/interpulse-${sid}.json"
}

_ip_read_state() {
  local sf="$1"
  if [[ -f "$sf" ]]; then
    cat "$sf"
  else
    echo '{"calls":0,"last_call_ts":0,"pressure":0,"heavy_calls":0,"est_tokens":0}'
  fi
}

_ip_write_state() {
  local sf="$1" state="$2"
  echo "$state" > "$sf"
}

# Extract context_window.remaining_percentage from hook stdin JSON.
# Returns empty string if field is absent (e.g., subagent or old Claude Code).
_ip_context_remaining() {
  echo "$1" | jq -r '.context_window.remaining_percentage // empty' 2>/dev/null
}

# Normalize raw remaining_percentage to usable context.
# Claude Code reserves ~16.5% for autocompact buffer, so usable context is
# only 83.5% of the window. Raw 35% remaining = ~22% usable.
# Returns integer percentage (0-100) of usable context remaining.
_ip_normalize_usable_context() {
  local raw="$1"
  [[ -z "$raw" ]] && return 1
  awk "BEGIN{
    buffer=16.5;
    usable_remaining = ($raw - buffer) / (100 - buffer) * 100;
    if (usable_remaining < 0) usable_remaining = 0;
    printf \"%d\", usable_remaining
  }" 2>/dev/null
}

# Map usable remaining % to a severity level.
# Returns: red (<10%), orange (<20%), yellow (<35%), or empty (green).
_ip_context_level() {
  local usable="$1"
  [[ -z "$usable" ]] && return 0
  if [[ "$usable" -lt 10 ]]; then
    echo "red"
  elif [[ "$usable" -lt 20 ]]; then
    echo "orange"
  elif [[ "$usable" -lt 35 ]]; then
    echo "yellow"
  fi
  # green: no output
}

# Return the higher severity of two levels.
# Ordering: red > orange > yellow > green (empty).
_ip_max_level() {
  local a="$1" b="$2"
  # Convert to numeric for comparison
  local _ip_na=0 _ip_nb=0
  case "$a" in yellow) _ip_na=1;; orange) _ip_na=2;; red) _ip_na=3;; esac
  case "$b" in yellow) _ip_nb=1;; orange) _ip_nb=2;; red) _ip_nb=3;; esac
  if [[ $_ip_na -ge $_ip_nb ]]; then echo "$a"; else echo "$b"; fi
}

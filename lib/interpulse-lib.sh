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

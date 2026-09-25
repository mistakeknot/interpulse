#!/usr/bin/env bash
# Shared library for interpulse hooks.
#
# Provides:
#   _ip_session_id     — extract session_id from stdin JSON
#   _ip_state_file     — path to session state file
#   _ip_read_state     — read state JSON (or default)
#   _ip_write_state    — write state JSON
#   _ip_transcript_path   — extract transcript_path from stdin JSON
#   _ip_transcript_tokens — real transcript context tokens + model (bounded tail read)
#   _ip_absolute_band     — band index for a real-token count above a threshold

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

# Extract transcript_path from hook stdin JSON. Empty if absent.
_ip_transcript_path() {
  echo "$1" | jq -r '.transcript_path // empty' 2>/dev/null
}

# Real (provider-reported) transcript context, read from a bounded tail of
# the transcript file rather than the whole thing (transcripts can run to
# many MB). Ported from Clavain hooks/context-handoff.sh: the last
# main-chain (isSidechain=false, type=assistant) record's
# input_tokens + cache_creation_input_tokens + cache_read_input_tokens is
# the measure, because that is what the model actually saw on its last
# turn -- not a heuristic estimate.
#
# Prints "<tokens> <model>" on stdout, tokens defaulting to 0 and model to
# "unknown" if no usable record is found (missing file, no jq, malformed
# transcript, only sidechain records, etc). Never fails the caller: on any
# error this still prints "0 unknown" so callers can test
# `[[ "$tokens" =~ ^[0-9]+$ ]]` uniformly instead of branching on a second
# failure mode. Callers that must distinguish "measured zero" from
# "couldn't measure" should treat missing/unreadable transcript_path as a
# distinct precondition before calling this (as both interpulse hooks do).
_ip_transcript_tokens() {
  local transcript="$1"
  local tail_bytes="${2:-262144}"
  local tokens=0 model="unknown" result

  [[ -n "$transcript" && -f "$transcript" ]] || { printf '%s %s\n' "$tokens" "$model"; return 0; }
  command -v jq >/dev/null 2>&1 || { printf '%s %s\n' "$tokens" "$model"; return 0; }

  result="$(tail -c "$tail_bytes" "$transcript" 2>/dev/null | jq -R -r '
      (try fromjson catch empty) as $obj
      | select($obj != null)
      | select($obj.type == "assistant"
               and (($obj.isSidechain // false) == false)
               and ($obj.message.usage != null))
      | (($obj.message.usage.input_tokens // 0)
         + ($obj.message.usage.cache_creation_input_tokens // 0)
         + ($obj.message.usage.cache_read_input_tokens // 0)) as $t
      | "\($t) \($obj.message.model // "unknown")"
  ' 2>/dev/null | tail -n 1)"

  if [[ -n "$result" ]]; then
    local t="${result%% *}"
    if [[ "$t" =~ ^[0-9]+$ ]]; then
      tokens="$t"
      model="${result#* }"
    fi
  fi
  printf '%s %s\n' "$tokens" "$model"
}

# Band index for a real-token count above a fixed absolute threshold,
# matching Clavain's context-handoff.sh band semantics: one band per 25k
# tokens, counted from zero regardless of where the threshold sits (so
# 100000/125000/150000 are bands 4/5/6). Prints empty (not 0) when tokens
# are below the threshold or not numeric, so callers can distinguish
# "below threshold" from "band 0" with a single string-emptiness check.
_ip_absolute_band() {
  local tokens="$1" threshold="${2:-100000}" band_size="${3:-25000}"
  [[ "$tokens" =~ ^[0-9]+$ ]] || return 0
  [[ "$threshold" =~ ^[0-9]+$ ]] || return 0
  [[ "$band_size" =~ ^[0-9]+$ ]] || band_size=25000
  (( tokens < threshold )) && return 0
  echo $(( tokens / band_size ))
}

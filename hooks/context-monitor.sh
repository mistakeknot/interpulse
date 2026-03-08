#!/usr/bin/env bash
# Context monitor — tracks session pressure via tool call count, time decay,
# heavy call weighting, cumulative token estimation, AND real context window
# remaining_percentage (when available from Claude Code).
#
# Dual-threshold: level = max(pressure_level, context_level)
#   Pressure thresholds (heuristic):
#     Green  : pressure < 60,  tokens < 150k  — no output
#     Yellow : pressure >= 60, tokens >= 150k  — moderate warning
#     Orange : pressure >= 90, tokens >= 180k  — wrap up warning
#     Red    : pressure >= 120, tokens >= 200k — auto-checkpoint + urgent warning
#   Context thresholds (ground truth, normalized for 16.5% autocompact buffer):
#     Green  : usable > 35%
#     Yellow : usable <= 35%
#     Orange : usable <= 20%
#     Red    : usable <= 10%
#
# Debounce: 5 tool calls between warnings. Severity escalation bypasses debounce.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SCRIPT_DIR/lib/interpulse-lib.sh"

INPUT=$(cat)
SID=$(_ip_session_id "$INPUT")
[[ -z "$SID" ]] && exit 0

TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
OUTPUT_LEN=$(echo "$INPUT" | jq -r '.tool_output // "" | length' 2>/dev/null || echo 0)

SF=$(_ip_state_file "$SID")
STATE=$(_ip_read_state "$SF")

NOW=$(date +%s)
LAST_TS=$(echo "$STATE" | jq -r '.last_call_ts // 0')
CALLS=$(echo "$STATE" | jq -r '.calls // 0')
PRESSURE=$(echo "$STATE" | jq -r '.pressure // 0')
HEAVY=$(echo "$STATE" | jq -r '.heavy_calls // 0')
EST_TOKENS=$(echo "$STATE" | jq -r '.est_tokens // 0')

# Time decay: 0.5 pressure points per 10 minutes of inactivity
DECAY=0
if [[ "$LAST_TS" -gt 0 ]]; then
  ELAPSED=$((NOW - LAST_TS))
  DECAY=$(awk "BEGIN{printf \"%.2f\", $ELAPSED / 600.0 * 0.5}" 2>/dev/null || echo "0")
fi

# Call weight: heavy tools consume more context
WEIGHT="1.0"
case "$TOOL" in
  Read|Grep|Task|WebFetch|WebSearch) WEIGHT="1.5"; HEAVY=$((HEAVY + 1)) ;;
esac

# Token estimate from tool output (1 token ~ 4 chars)
NEW_TOKENS=$((OUTPUT_LEN / 4))
EST_TOKENS=$((EST_TOKENS + NEW_TOKENS))

# Pressure update: decay old pressure, add new call weight
PRESSURE=$(awk "BEGIN{v=$PRESSURE - $DECAY; if(v<0)v=0; printf \"%.2f\", v + $WEIGHT}" 2>/dev/null || echo "$PRESSURE")
CALLS=$((CALLS + 1))

# Write updated state
NEW_STATE=$(jq -n \
  --argjson calls "$CALLS" \
  --argjson ts "$NOW" \
  --argjson pressure "$PRESSURE" \
  --argjson heavy "$HEAVY" \
  --argjson tokens "$EST_TOKENS" \
  '{calls:$calls, last_call_ts:$ts, pressure:$pressure, heavy_calls:$heavy, est_tokens:$tokens}')
_ip_write_state "$SF" "$NEW_STATE"

# Determine pressure-based threshold level
PRESSURE_LEVEL=""
if (( EST_TOKENS > 200000 )) || awk "BEGIN{exit($PRESSURE > 120 ? 0 : 1)}" 2>/dev/null; then
  PRESSURE_LEVEL="red"
elif (( EST_TOKENS > 180000 )) || awk "BEGIN{exit($PRESSURE > 90 ? 0 : 1)}" 2>/dev/null; then
  PRESSURE_LEVEL="orange"
elif (( EST_TOKENS > 150000 )) || awk "BEGIN{exit($PRESSURE > 60 ? 0 : 1)}" 2>/dev/null; then
  PRESSURE_LEVEL="yellow"
fi

# Determine context-window threshold level (ground truth when available)
CONTEXT_REMAINING=$(_ip_context_remaining "$INPUT")
CONTEXT_USABLE=""
CONTEXT_LEVEL=""
if [[ -n "$CONTEXT_REMAINING" ]]; then
  CONTEXT_USABLE=$(_ip_normalize_usable_context "$CONTEXT_REMAINING")
  CONTEXT_LEVEL=$(_ip_context_level "$CONTEXT_USABLE")
fi

# Dual-threshold: take the higher severity
LEVEL=$(_ip_max_level "${PRESSURE_LEVEL:-}" "${CONTEXT_LEVEL:-}")

# Debounce: 5 tool calls between warnings, severity escalation bypasses
DEBOUNCE_FILE="/tmp/interpulse-debounce-${SID}.json"
DEBOUNCE_CALLS=5
if [[ -n "$LEVEL" ]]; then
  _ip_db_counter=0
  _ip_db_last_level=""
  if [[ -f "$DEBOUNCE_FILE" ]]; then
    _ip_db_counter=$(jq -r '.calls_since_warn // 0' "$DEBOUNCE_FILE" 2>/dev/null || echo 0)
    _ip_db_last_level=$(jq -r '.last_level // empty' "$DEBOUNCE_FILE" 2>/dev/null)
  fi
  _ip_db_counter=$((_ip_db_counter + 1))

  # Check for severity escalation (e.g., yellow→orange or orange→red)
  _ip_escalated=false
  if [[ -n "$_ip_db_last_level" && "$LEVEL" != "$_ip_db_last_level" ]]; then
    _ip_cur_num=0; _ip_last_num=0
    case "$LEVEL" in yellow) _ip_cur_num=1;; orange) _ip_cur_num=2;; red) _ip_cur_num=3;; esac
    case "$_ip_db_last_level" in yellow) _ip_last_num=1;; orange) _ip_last_num=2;; red) _ip_last_num=3;; esac
    [[ $_ip_cur_num -gt $_ip_last_num ]] && _ip_escalated=true
  fi

  # Suppress warning if within debounce window and not escalating
  if [[ "$_ip_db_counter" -lt "$DEBOUNCE_CALLS" && "$_ip_escalated" == "false" && -n "$_ip_db_last_level" ]]; then
    jq -n -c --argjson c "$_ip_db_counter" --arg l "${_ip_db_last_level}" \
      '{calls_since_warn:$c, last_level:$l}' > "$DEBOUNCE_FILE" 2>/dev/null || true
    LEVEL=""  # suppress this warning
  else
    # Reset debounce counter — warning will fire
    jq -n -c --arg l "$LEVEL" '{calls_since_warn:0, last_level:$l}' > "$DEBOUNCE_FILE" 2>/dev/null || true
  fi
elif [[ -f "$DEBOUNCE_FILE" ]]; then
  # Below all thresholds — increment counter but keep tracking
  _ip_db_counter=$(jq -r '.calls_since_warn // 0' "$DEBOUNCE_FILE" 2>/dev/null || echo 0)
  jq -n -c --argjson c "$((_ip_db_counter + 1))" --arg l "$(jq -r '.last_level // empty' "$DEBOUNCE_FILE" 2>/dev/null)" \
    '{calls_since_warn:$c, last_level:$l}' > "$DEBOUNCE_FILE" 2>/dev/null || true
fi

# Write pressure level to interband for statusline and other consumers
_ipm_ib_lib=""
_ipm_hooks_dir="$(cd "$(dirname "$0")" && pwd)"
_ipm_repo_root="$(git -C "$_ipm_hooks_dir" rev-parse --show-toplevel 2>/dev/null || true)"
for _ipm_ib_candidate in \
    "${INTERBAND_LIB:-}" \
    "${_ipm_hooks_dir}/../../../infra/interband/lib/interband.sh" \
    "${_ipm_hooks_dir}/../../../interband/lib/interband.sh" \
    "${_ipm_repo_root}/../interband/lib/interband.sh" \
    "${HOME}/.local/share/interband/lib/interband.sh"; do
  [[ -n "$_ipm_ib_candidate" && -f "$_ipm_ib_candidate" ]] && _ipm_ib_lib="$_ipm_ib_candidate" && break
done

if [[ -n "$_ipm_ib_lib" ]]; then
  source "$_ipm_ib_lib" || true

  _ipm_ib_ctx_args=()
  if [[ -n "${CONTEXT_USABLE:-}" ]]; then
    _ipm_ib_ctx_args+=(--argjson context_usable "$CONTEXT_USABLE")
  fi
  if [[ -n "${CONTEXT_REMAINING:-}" ]]; then
    _ipm_ib_ctx_args+=(--argjson context_raw "$CONTEXT_REMAINING")
  fi
  # Use the pre-debounce level for interband (consumers want raw severity, not debounced)
  _ipm_ib_raw_level=$(_ip_max_level "${PRESSURE_LEVEL:-}" "${CONTEXT_LEVEL:-}")
  _ipm_ib_payload=$(jq -n -c \
    --arg level "${_ipm_ib_raw_level:-green}" \
    --argjson pressure "$PRESSURE" \
    --argjson est_tokens "$EST_TOKENS" \
    --argjson ts "$NOW" \
    "${_ipm_ib_ctx_args[@]}" \
    '{level:$level, pressure:$pressure, est_tokens:$est_tokens, ts:$ts} + (if $ARGS.named | has("context_usable") then {context_usable:$ARGS.named.context_usable} else {} end) + (if $ARGS.named | has("context_raw") then {context_raw:$ARGS.named.context_raw} else {} end)')
  _ipm_ib_file=$(interband_path "interpulse" "pressure" "$SID" 2>/dev/null) || _ipm_ib_file=""
  if [[ -n "$_ipm_ib_file" ]]; then
    interband_write "$_ipm_ib_file" "interpulse" "context_pressure" "$SID" "$_ipm_ib_payload" 2>/dev/null || true
    interband_prune_channel "interpulse" "pressure" 2>/dev/null || true
  fi
fi

# Only emit output when a threshold is crossed
case "$LEVEL" in
  red)
    CHECKPOINT="/tmp/interpulse-checkpoint-${SID}.md"
    {
      echo "# Session Checkpoint (auto-generated)"
      echo "Session: $SID"
      echo "Pressure: $PRESSURE | Est. tokens: ~${EST_TOKENS}"
      [[ -n "${CONTEXT_USABLE:-}" ]] && echo "Context window: ${CONTEXT_USABLE}% usable remaining (raw: ${CONTEXT_REMAINING}%)"
      echo "Tool calls: $CALLS ($HEAVY heavy)"
      echo "Time: $(date -Iseconds)"
    } > "$CHECKPOINT"
    _ipm_ctx_detail=""
    [[ -n "${CONTEXT_USABLE:-}" ]] && _ipm_ctx_detail=", context: ${CONTEXT_USABLE}% usable remaining"
    jq -n --arg msg "Context is near exhaustion (pressure: $PRESSURE, ~${EST_TOKENS} tokens${_ipm_ctx_detail}). Checkpoint written to $CHECKPOINT. Commit your work and wrap up NOW." \
      '{"additionalContext": $msg}'
    ;;
  orange)
    # Smart checkpoint: signal intermem via interband at orange pressure
    _ipm_checkpoint_msg=""
    _ipm_last_checkpoint="/tmp/interpulse-intermem-checkpoint-${SID}"
    _ipm_cp_lock="/tmp/interpulse-cp-lock-${SID}"
    if [[ ! -f "$_ipm_last_checkpoint" || $(( NOW - $(stat -c %Y "$_ipm_last_checkpoint" 2>/dev/null || echo 0) )) -gt 900 ]]; then
      if mkdir "$_ipm_cp_lock" 2>/dev/null; then
        touch "$_ipm_last_checkpoint" 2>/dev/null || true
        rmdir "$_ipm_cp_lock" 2>/dev/null || true
        if [[ -n "${_ipm_ib_lib:-}" ]]; then
          _ipm_cp_payload=$(jq -n -c --argjson ts "$NOW" '{"trigger":"orange_pressure","ts":$ts}')
          _ipm_cp_file=$(interband_path "interpulse" "checkpoint" "$SID" 2>/dev/null) || _ipm_cp_file=""
          if [[ -n "$_ipm_cp_file" ]]; then
            interband_write "$_ipm_cp_file" "interpulse" "checkpoint_needed" "$SID" "$_ipm_cp_payload" 2>/dev/null || true
            interband_prune_channel "interpulse" "checkpoint" 2>/dev/null || true
            _ipm_checkpoint_msg=" Consider synthesizing session memory before continuing."
          fi
        fi
      fi
    fi
    _ipm_ctx_detail=""
    [[ -n "${CONTEXT_USABLE:-}" ]] && _ipm_ctx_detail=", context: ${CONTEXT_USABLE}% usable remaining"
    jq -n --arg msg "Context pressure is high (pressure: $PRESSURE, ~${EST_TOKENS} tokens${_ipm_ctx_detail}). Finish current work and commit. Avoid launching new subagents.${_ipm_checkpoint_msg}" \
      '{"additionalContext": $msg}'
    ;;
  yellow)
    _ipm_ctx_detail=""
    [[ -n "${CONTEXT_USABLE:-}" ]] && _ipm_ctx_detail=", context: ${CONTEXT_USABLE}% usable remaining"
    jq -n --arg msg "Context pressure is moderate (pressure: $PRESSURE, ~${EST_TOKENS} tokens${_ipm_ctx_detail}). Consider wrapping up current task before starting new ones." \
      '{"additionalContext": $msg}'
    ;;
esac

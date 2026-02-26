#!/usr/bin/env bash
# Context monitor — tracks session pressure via tool call count, time decay,
# heavy call weighting, and cumulative token estimation.
#
# Thresholds (pressure OR tokens, whichever triggers first):
#   Green  : pressure < 60,  tokens < 150k  — no output
#   Yellow : pressure >= 60, tokens >= 150k  — moderate warning
#   Orange : pressure >= 90, tokens >= 180k  — wrap up warning
#   Red    : pressure >= 120, tokens >= 200k — auto-checkpoint + urgent warning
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

# Determine threshold level
LEVEL=""
if (( EST_TOKENS > 200000 )) || awk "BEGIN{exit($PRESSURE > 120 ? 0 : 1)}" 2>/dev/null; then
  LEVEL="red"
elif (( EST_TOKENS > 180000 )) || awk "BEGIN{exit($PRESSURE > 90 ? 0 : 1)}" 2>/dev/null; then
  LEVEL="orange"
elif (( EST_TOKENS > 150000 )) || awk "BEGIN{exit($PRESSURE > 60 ? 0 : 1)}" 2>/dev/null; then
  LEVEL="yellow"
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

  _ipm_ib_payload=$(jq -n -c \
    --arg level "${LEVEL:-green}" \
    --argjson pressure "$PRESSURE" \
    --argjson est_tokens "$EST_TOKENS" \
    --argjson ts "$NOW" \
    '{level:$level, pressure:$pressure, est_tokens:$est_tokens, ts:$ts}')
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
      echo "Tool calls: $CALLS ($HEAVY heavy)"
      echo "Time: $(date -Iseconds)"
    } > "$CHECKPOINT"
    jq -n --arg msg "Context is near exhaustion (pressure: $PRESSURE, ~${EST_TOKENS} tokens). Checkpoint written to $CHECKPOINT. Commit your work and wrap up NOW." \
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
    jq -n --arg msg "Context pressure is high (pressure: $PRESSURE, ~${EST_TOKENS} tokens). Finish current work and commit. Avoid launching new subagents.${_ipm_checkpoint_msg}" \
      '{"additionalContext": $msg}'
    ;;
  yellow)
    jq -n --arg msg "Context pressure is moderate (pressure: $PRESSURE, ~${EST_TOKENS} tokens). Consider wrapping up current task before starting new ones." \
      '{"additionalContext": $msg}'
    ;;
esac

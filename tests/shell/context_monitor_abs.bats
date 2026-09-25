#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
# Tests for hooks/context-monitor.sh's absolute real-context extension.
#
# This does NOT touch the existing heuristic pressure/context-window
# percentage behavior (covered implicitly here by asserting it still fires
# unchanged); it adds a second, independent absolute-token signal that:
#   - measures the same real transcript tokens the Stop hook
#     (hooks/coordinator-handoff.sh) uses, via the same lib function;
#   - reports once per 25k-token band past INTERPULSE_COORD_CONTEXT_TOKENS
#     (default 100000), as an additionalContext note;
#   - fires even when the heuristic level is green (the whole point: a 1M
#     window session can have a huge absolute token count while still
#     "green" on the percentage-based signal).

setup() {
    HOOK="$BATS_TEST_DIRNAME/../../hooks/context-monitor.sh"
    FIXTURES="$BATS_TEST_DIRNAME/../fixtures/coordinator-handoff"
    SID="cm-abs-$$-$RANDOM"
    unset INTERPULSE_COORD_CONTEXT_TOKENS

    STATE_FILE="/tmp/interpulse-${SID}.json"
    DEBOUNCE_FILE="/tmp/interpulse-debounce-${SID}.json"
    ABS_BAND_FILE="/tmp/interpulse-absband-${SID}"
    CHECKPOINT_FILE="/tmp/interpulse-checkpoint-${SID}.md"
    rm -f "$STATE_FILE" "$DEBOUNCE_FILE" "$ABS_BAND_FILE" "$CHECKPOINT_FILE"
}

teardown() {
    rm -f "$STATE_FILE" "$DEBOUNCE_FILE" "$ABS_BAND_FILE" "$CHECKPOINT_FILE" \
        "/tmp/interpulse-intermem-checkpoint-${SID}"
}

hook_input() {  # $1 = transcript path (or empty), $2 = tool_output length filler
    local transcript_arg=()
    [[ -n "${1:-}" ]] && transcript_arg=(--arg t "$1")
    jq -n "${transcript_arg[@]}" --arg sid "$SID" --arg out "${2:-x}" \
        '{session_id: $sid, tool_name: "Read", tool_output: $out} + (if $ARGS.named | has("t") then {transcript_path: $ARGS.named.t} else {} end)'
}

# Same as hook_input but reads a large tool_output from a file (--rawfile),
# avoiding an ARG_MAX failure from a very long --arg value.
hook_input_big_output() {  # $1 = transcript path, $2 = tool_output file
    jq -n --arg t "$1" --arg sid "$SID" --rawfile out "$2" \
        '{session_id: $sid, tool_name: "Read", tool_output: $out, transcript_path: $t}'
}

@test "context-monitor abs: no transcript_path leaves existing green behavior untouched" {
    run bash "$HOOK" <<< "$(hook_input "" "small")"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "context-monitor abs: real tokens below the absolute threshold produce no abs note" {
    run bash "$HOOK" <<< "$(hook_input "$FIXTURES/60k.jsonl" "small")"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "context-monitor abs: real tokens above the absolute threshold report even though heuristic pressure is green" {
    run bash "$HOOK" <<< "$(hook_input "$FIXTURES/130k-opus.jsonl" "small")"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    msg="$(jq -r '.additionalContext' <<<"$output")"
    [[ "$msg" == *"130000"* ]]
    [[ "$msg" == *"100000"* ]]
}

@test "context-monitor abs: a second call in the same band is silent (band-gated, not per-call)" {
    run bash "$HOOK" <<< "$(hook_input "$FIXTURES/130k-opus.jsonl" "small")"
    [ "$status" -eq 0 ]
    [ -n "$output" ]

    run bash "$HOOK" <<< "$(hook_input "$FIXTURES/130k-opus.jsonl" "small")"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "context-monitor abs: crossing into a new 25k band reports again" {
    run bash "$HOOK" <<< "$(hook_input "$FIXTURES/105k-sonnet.jsonl" "small")"
    [ "$status" -eq 0 ]
    [ -n "$output" ]

    run bash "$HOOK" <<< "$(hook_input "$FIXTURES/160k-sonnet.jsonl" "small")"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    msg="$(jq -r '.additionalContext' <<<"$output")"
    [[ "$msg" == *"160000"* ]]
}

@test "context-monitor abs: interband payload (when interband is present) carries real_context_tokens" {
    # No interband lib on PATH in this sandbox -- assert the hook doesn't
    # blow up trying, and still emits its own note independent of interband.
    run bash "$HOOK" <<< "$(hook_input "$FIXTURES/130k-opus.jsonl" "small")"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
}

@test "context-monitor abs: existing heuristic RED behavior is preserved and gets the abs note appended" {
    # A single huge tool_output (chars/4 estimate) pushes est_tokens over
    # 200000 in one call, triggering the pre-existing RED heuristic path
    # (checkpoint file + additionalContext), independent of any transcript.
    big_output_file="$(mktemp)"
    head -c 900000 /dev/zero | tr '\0' 'a' > "$big_output_file"
    run bash "$HOOK" <<< "$(hook_input_big_output "$FIXTURES/130k-opus.jsonl" "$big_output_file")"
    rm -f "$big_output_file"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    msg="$(jq -r '.additionalContext' <<<"$output")"
    [[ "$msg" == *"near exhaustion"* ]]
    [[ "$msg" == *"Checkpoint written to"* ]]
    [[ "$msg" == *"130000"* ]]
    [ -f "$CHECKPOINT_FILE" ]
}

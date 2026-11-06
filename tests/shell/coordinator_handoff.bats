#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
# Tests for hooks/coordinator-handoff.sh, ported (not copied) from Clavain
# hooks/context-handoff.sh (bead mk-42j9.13).
#
# The hook is a Stop hook. It measures REAL transcript context from the last
# main-chain assistant record (via lib/interpulse-lib.sh's
# _ip_transcript_tokens), and for bb sessions above
# INTERPULSE_COORD_CONTEXT_TOKENS (default 90000, INTERPULSE_COORD_CONTEXT_DEFAULT):
#   - a coordinator thread gets a blocking decision naming the exact
#     `bb handoff` commands, unless rotation is already enabled at or under
#     the threshold AND still within the first 25k-token band since
#     rotate-at;
#   - a worker thread gets an advisory systemMessage, never a block.
#
# Every failure path is silent, exit 0. The band file is only written after a
# full determination completes (fail-open-state-drift hardening): a bb
# failure/timeout must NOT freeze the band as "checked" -- see the dedicated
# section below.

setup() {
    HOOK="$BATS_TEST_DIRNAME/../../hooks/coordinator-handoff.sh"
    FIXTURES="$BATS_TEST_DIRNAME/../fixtures/coordinator-handoff"

    STUB_DIR="$(mktemp -d)"
    STATE_DIR="$(mktemp -d)"
    export PATH="$STUB_DIR:$PATH"
    export INTERPULSE_COORD_STATE_DIR="$STATE_DIR"
    export BB_THREAD_ID="thr_test0001"
    unset INTERPULSE_COORD_HOOK
    unset INTERPULSE_COORD_CONTEXT_TOKENS
    unset INTERPULSE_COORD_TIME_BUDGET_S
    # Keep find_clavain_coordinator_model()'s fallback lookup hermetic: point
    # it at locations that do not exist rather than this host's real
    # ~/.claude/plugins files, so these tests never depend on what happens to
    # be installed on the machine running them.
    export CLAVAIN_INSTALLED_FILE="$STATE_DIR/no-such-installed_plugins.json"
    export CLAUDE_PLUGIN_CACHE_ROOT="$STATE_DIR/no-such-cache"

}

teardown() {
    rm -rf "$STUB_DIR" "$STATE_DIR"
}

# make_bb_stub <coordinator-status-json> [<children-json>] [<sleep-secs>] [<exit-code>] [<context-json>] [<context-exit-code>]
make_bb_stub() {
    local status_json="${1:-{\"marking\":null,\"rotationEnabled\":false\}}"
    local children_json="${2:-[]}"
    local sleep_secs="${3:-0}"
    local exit_code="${4:-0}"
    local context_json="${5:-{\"usage\":{\"modelContextWindow\":200000\}\}}"
    local context_exit_code="${6:-0}"
    cat > "$STUB_DIR/bb" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$STATE_DIR/bb-calls"
sleep ${sleep_secs}
if [[ "\$1 \$2 \$3" == "handoff coordinator status" ]]; then
    printf '%s\n' '$status_json'
    exit ${exit_code}
fi
if [[ "\$1 \$2" == "thread list" ]]; then
    printf '%s\n' '$children_json'
    exit \${STUB_CHILDREN_EXIT:-${exit_code}}
fi
if [[ "\$1 \$2" == "thread context" ]]; then
    printf '%s\n' '$context_json'
    exit ${context_exit_code}
fi
exit 1
EOF
    chmod +x "$STUB_DIR/bb"
}

hook_input() {  # $1 = transcript path, $2 = stop_hook_active (true/false), $3 = session_id
    jq -n --arg t "$1" --argjson s "${2:-false}" --arg id "${3:-sess-1}" \
        '{transcript_path: $t, stop_hook_active: $s, session_id: $id}'
}

@test "coordinator-handoff: silent below the threshold" {
    make_bb_stub
    run bash "$HOOK" <<< "$(hook_input "$FIXTURES/60k.jsonl")"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -e "$STATE_DIR/bb-calls" ]   # bb consulted only above the threshold
}

@test "coordinator-handoff: silent with no BB_THREAD_ID" {
    unset BB_THREAD_ID
    make_bb_stub
    run bash "$HOOK" <<< "$(hook_input "$FIXTURES/130k-opus.jsonl")"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -e "$STATE_DIR/bb-calls" ]
}

@test "coordinator-handoff: silent with stop_hook_active" {
    make_bb_stub
    run bash "$HOOK" <<< "$(hook_input "$FIXTURES/130k-opus.jsonl" true)"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "coordinator-handoff: default threshold is the 90000 named constant, so a 95k coordinator blocks" {
    grep -qx 'INTERPULSE_COORD_CONTEXT_DEFAULT=90000' "$BATS_TEST_DIRNAME/../../lib/interpulse-lib.sh"
    make_bb_stub '{"marking":{},"rotationEnabled":false}'
    run bash "$HOOK" <<< "$(hook_input "$FIXTURES/95k-sonnet.jsonl" false "sess-95k")"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.decision' <<<"$output")" = "block" ]
    [[ "$(jq -r '.reason' <<<"$output")" == *"bb handoff coordinator enable --self --rotate-at 90000"* ]]
}

@test "coordinator-handoff: INTERPULSE_COORD_CONTEXT_TOKENS still overrides the default (95k under a 100000 override is silent)" {
    make_bb_stub '{"marking":{},"rotationEnabled":false}'
    export INTERPULSE_COORD_CONTEXT_TOKENS=100000
    run bash "$HOOK" <<< "$(hook_input "$FIXTURES/95k-sonnet.jsonl" false "sess-95k-override")"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "coordinator-handoff: rotation enabled just past rotate-at (first band) stays silent" {
    make_bb_stub '{"marking":{"rotateAt":90000},"rotationEnabled":true}'
    run bash "$HOOK" <<< "$(hook_input "$FIXTURES/105k-sonnet.jsonl")"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "coordinator-handoff: fractional rotateAt against a live 1000000 window blocks" {
    make_bb_stub '{"marking":{"rotateAt":0.3},"rotationEnabled":true}' '[]' 0 0 \
        '{"usage":{"modelContextWindow":1000000}}'
    run bash "$HOOK" <<< "$(hook_input "$FIXTURES/130k-sonnet.jsonl")"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    decision="$(jq -r '.decision' <<<"$output")"
    [ "$decision" = "block" ]
}

@test "coordinator-handoff: fractional rotateAt against a live 300000 window, still in the first band, stays silent" {
    make_bb_stub '{"marking":{"rotateAt":0.3},"rotationEnabled":true}' '[]' 0 0 \
        '{"usage":{"modelContextWindow":300000}}'
    run bash "$HOOK" <<< "$(hook_input "$FIXTURES/105k-sonnet.jsonl")"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "coordinator-handoff: fractional rotateAt with a failing context lookup blocks" {
    make_bb_stub '{"marking":{"rotateAt":0.3},"rotationEnabled":true}' '[]' 0 0 \
        '{}' 1
    run bash "$HOOK" <<< "$(hook_input "$FIXTURES/130k-sonnet.jsonl")"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    decision="$(jq -r '.decision' <<<"$output")"
    [ "$decision" = "block" ]
}

@test "coordinator-handoff: worker above threshold gets an advisory systemMessage, not a block" {
    make_bb_stub '{"marking":null,"rotationEnabled":false}' '[]'
    run bash "$HOOK" <<< "$(hook_input "$FIXTURES/130k-opus.jsonl")"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    msg="$(jq -r '.systemMessage' <<<"$output")"
    [ -n "$msg" ] && [ "$msg" != "null" ]
    decision="$(jq -r '.decision // empty' <<<"$output")"
    [ -z "$decision" ]
}

@test "coordinator-handoff: a second Stop in the same band is silent" {
    make_bb_stub '{"marking":{},"rotationEnabled":false}'
    run bash "$HOOK" <<< "$(hook_input "$FIXTURES/130k-opus.jsonl" false "sess-band")"
    [ "$status" -eq 0 ]
    [ -n "$output" ]

    run bash "$HOOK" <<< "$(hook_input "$FIXTURES/130k-opus.jsonl" false "sess-band")"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    calls="$(wc -l < "$STATE_DIR/bb-calls")"
    [ "$calls" -eq 2 ]   # status + title lookup, once
}

@test "coordinator-handoff: a bb timeout is silent and exits 0" {
    make_bb_stub '{"marking":null,"rotationEnabled":false}' '[]' 5
    run bash "$HOOK" <<< "$(hook_input "$FIXTURES/130k-opus.jsonl")"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "coordinator-handoff: a bb failure (nonzero exit) is silent and exits 0" {
    make_bb_stub '{"marking":null,"rotationEnabled":false}' '[]' 0 1
    run bash "$HOOK" <<< "$(hook_input "$FIXTURES/130k-opus.jsonl")"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "coordinator-handoff: INTERPULSE_COORD_HOOK=off is silent" {
    export INTERPULSE_COORD_HOOK=off
    make_bb_stub '{"marking":{},"rotationEnabled":false}'
    run bash "$HOOK" <<< "$(hook_input "$FIXTURES/130k-opus.jsonl")"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -e "$STATE_DIR/bb-calls" ]
}

@test "coordinator-handoff: a sidechain record at end of transcript is excluded from context measure" {
    make_bb_stub '{"marking":{},"rotationEnabled":false}'
    run bash "$HOOK" <<< "$(hook_input "$FIXTURES/sidechain.jsonl")"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -e "$STATE_DIR/bb-calls" ]
}

@test "coordinator-handoff: a truncated last record fails open (silent), not older usage" {
    make_bb_stub '{"marking":{},"rotationEnabled":false}'
    run bash "$HOOK" <<< "$(hook_input "$FIXTURES/truncated.jsonl")"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -e "$STATE_DIR/bb-calls" ]
}

@test "coordinator-handoff: a bounded tail that starts mid-record still measures the last record" {
    big="$STATE_DIR/big.jsonl"
    { printf '{"type":"user","message":{"content":"'; head -c 300000 /dev/zero | tr '\0' x; printf '"}}\n'; } > "$big"
    tail -n 1 "$FIXTURES/130k-opus.jsonl" >> "$big"
    make_bb_stub '{"marking":{},"rotationEnabled":false}'
    run bash "$HOOK" <<< "$(hook_input "$big")"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.decision' <<<"$output")" = "block" ]
}

@test "coordinator-handoff: a complete malformed record exactly at the tail boundary fails open" {
    big="$STATE_DIR/boundary.jsonl"
    last="$(tail -n 1 "$FIXTURES/130k-opus.jsonl")"
    last_len=$(( ${#last} + 1 ))
    pad=$(( 262144 - last_len - 5 ))
    { printf '{"type":"user","message":{"content":"first"}}\n'
      printf '{bad'; head -c "$pad" /dev/zero | tr '\0' x; printf '\n'
      printf '%s\n' "$last"; } > "$big"
    [ "$(tail -c 262145 "$big" | head -c 1 | od -An -tx1 | tr -d ' \n')" = "0a" ]
    make_bb_stub '{"marking":{},"rotationEnabled":false}'
    run bash "$HOOK" <<< "$(hook_input "$big")"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -e "$STATE_DIR/bb-calls" ]
}

@test "coordinator-handoff: a thread that gains children becomes a coordinator in a later band" {
    COUNTER="$STATE_DIR/list-calls"
    cat > "$STUB_DIR/bb" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$STATE_DIR/bb-calls"
if [[ "\$1 \$2 \$3" == "handoff coordinator status" ]]; then
    printf '%s\n' '{"marking":null,"rotationEnabled":false}'
    exit 0
fi
if [[ "\$1 \$2" == "thread list" ]]; then
    n=0
    [[ -f "$COUNTER" ]] && n="\$(cat "$COUNTER")"
    n=\$((n + 1))
    echo "\$n" > "$COUNTER"
    if [[ "\$n" -eq 1 ]]; then
        printf '%s\n' '[]'
    else
        printf '%s\n' '[{"id":"thr_child1","archivedAt":null}]'
    fi
    exit 0
fi
if [[ "\$1 \$2" == "thread context" ]]; then
    printf '%s\n' '{"usage":{"modelContextWindow":200000}}'
    exit 0
fi
exit 1
EOF
    chmod +x "$STUB_DIR/bb"

    run bash "$HOOK" <<< "$(hook_input "$FIXTURES/105k-sonnet.jsonl" false "sess-children")"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    decision="$(jq -r '.decision // empty' <<<"$output")"
    [ -z "$decision" ]
    msg="$(jq -r '.systemMessage // empty' <<<"$output")"
    [ -n "$msg" ]

    run bash "$HOOK" <<< "$(hook_input "$FIXTURES/130k-sonnet.jsonl" false "sess-children")"
    [ "$status" -eq 0 ]
    decision="$(jq -r '.decision // empty' <<<"$output")"
    [ "$decision" = "block" ]
}

@test "coordinator-handoff: a window lookup that fails once retries in the next band" {
    cat > "$STUB_DIR/bb" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$STATE_DIR/bb-calls"
if [[ "\$1 \$2 \$3" == "handoff coordinator status" ]]; then
    printf '%s\n' '{"marking":{"rotateAt":0.3},"rotationEnabled":true}'
    exit 0
fi
if [[ "\$1 \$2" == "thread list" ]]; then
    printf '%s\n' '[]'
    exit 0
fi
if [[ "\$1 \$2" == "thread context" ]]; then
    exit 1
fi
exit 1
EOF
    chmod +x "$STUB_DIR/bb"

    run bash "$HOOK" <<< "$(hook_input "$FIXTURES/105k-sonnet.jsonl" false "sess-window-retry")"
    [ "$status" -eq 0 ]
    [ -n "$output" ]

    run bash "$HOOK" <<< "$(hook_input "$FIXTURES/130k-sonnet.jsonl" false "sess-window-retry")"
    [ "$status" -eq 0 ]
    [ -n "$output" ]

    calls="$(grep -c 'thread context' "$STATE_DIR/bb-calls")"
    [ "$calls" -eq 2 ]
}

# --- Fail-open-state-drift hardening: a bb failure must NOT freeze the band
#     as "checked" -- the next Stop, even within the same band, must retry
#     against bb rather than silently staying quiet for a full 25k tokens on
#     an incomplete determination. -------------------------------------------

@test "coordinator-handoff: a bb failure does not persist the band -- the next Stop in the same band retries" {
    # First bb call in this band fails outright (status lookup nonzero exit).
    # The Clavain original wrote its band-throttle file BEFORE this call, so
    # a retry within the same band would have found the band already marked
    # and stayed silent forever for these 25k tokens. This hook must instead
    # leave the band unmarked so the very next Stop (same band, same
    # transcript here) retries and gets a real determination.
    make_bb_stub '{"marking":{},"rotationEnabled":false}' '[]' 0 1
    run bash "$HOOK" <<< "$(hook_input "$FIXTURES/130k-opus.jsonl" false "sess-driftfix")"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    first_calls="$(wc -l < "$STATE_DIR/bb-calls")"

    # Now bb recovers. A second Stop in the exact same 25k band must retry
    # (not be silenced by a band file the first, failed attempt should never
    # have written) and must reach the real coordinator-block outcome.
    make_bb_stub '{"marking":{},"rotationEnabled":false}' '[]' 0 0
    run bash "$HOOK" <<< "$(hook_input "$FIXTURES/130k-opus.jsonl" false "sess-driftfix")"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    decision="$(jq -r '.decision' <<<"$output")"
    [ "$decision" = "block" ]

    second_calls="$(wc -l < "$STATE_DIR/bb-calls")"
    [ "$second_calls" -gt "$first_calls" ]
}

@test "coordinator-handoff: a children-list bb failure does not persist the band either" {
    # Status lookup succeeds (not marked), but the children lookup that
    # follows fails. This must not persist the band as checked.
    make_bb_stub '{"marking":null,"rotationEnabled":false}' '[]' 0 0
    STUB_CHILDREN_EXIT=1 run bash "$HOOK" <<< "$(hook_input "$FIXTURES/130k-opus.jsonl" false "sess-childfail")"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    grep -q "thread list" "$STATE_DIR/bb-calls"

    make_bb_stub '{"marking":null,"rotationEnabled":false}' '[{"id":"thr_c","archivedAt":null}]' 0 0
    run bash "$HOOK" <<< "$(hook_input "$FIXTURES/130k-opus.jsonl" false "sess-childfail")"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    decision="$(jq -r '.decision // empty' <<<"$output")"
    [ "$decision" = "block" ]
}

@test "coordinator-handoff: an unwritable state dir does not abort the whole determination" {
    # mkdir -p fails (state dir path points at a file, not a directory) --
    # this must not make the hook exit silently without ever consulting bb;
    # it should still reach a full, correct determination this Stop, just
    # without the band-throttle optimization persisting across calls.
    rm -rf "$STATE_DIR"
    touch "$STATE_DIR"   # a plain file where mkdir -p expects a directory
    make_bb_stub '{"marking":{},"rotationEnabled":false}'
    run bash "$HOOK" <<< "$(hook_input "$FIXTURES/130k-opus.jsonl" false "sess-nostatewrite")"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    decision="$(jq -r '.decision' <<<"$output")"
    [ "$decision" = "block" ]
}

# --- P1-1: headless / dispatched-child guard --------------------------------

@test "coordinator-handoff: a headless (claude -p) session is silent, with no bb call" {
    # Fake ps: reports a parent chain that terminates at a "claude -p ..."
    # process, so _ip_is_headless must detect it without any real ancestor
    # process actually being headless (bats itself is not).
    cat > "$STUB_DIR/ps" <<'EOF'
#!/usr/bin/env bash
for arg in "$@"; do
    case "$arg" in
        ppid=)
            printf '4242\n'
            exit 0
            ;;
    esac
done
for arg in "$@"; do
    case "$arg" in
        args=)
            printf 'claude -p do the thing\n'
            exit 0
            ;;
    esac
done
exit 1
EOF
    chmod +x "$STUB_DIR/ps"

    make_bb_stub '{"marking":{},"rotationEnabled":false}'
    run bash "$HOOK" <<< "$(hook_input "$FIXTURES/130k-opus.jsonl" false "sess-headless")"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -e "$STATE_DIR/bb-calls" ]
}

@test "coordinator-handoff: a wrapper shell mentioning claude does not mask a headless claude ancestor" {
    cat > "$STUB_DIR/ps" <<'EOF'
#!/usr/bin/env bash
want=""
for a in "$@"; do case "$a" in ppid=|args=) want="$a";; esac; done
pid=""
for a in "$@"; do case "$a" in [0-9]*) pid="$a";; esac; done
if [[ "$want" == "ppid=" ]]; then
    case "$pid" in
        4242) echo 4243 ;;
        *) echo 4242 ;;
    esac
    exit 0
fi
case "$pid" in
    4242) echo '/bin/sh -c /home/u/.claude/plugins/x/hooks/coordinator-handoff.sh' ;;
    4243) echo 'claude -p do the thing' ;;
    *) exit 1 ;;
esac
EOF
    chmod +x "$STUB_DIR/ps"
    make_bb_stub '{"marking":{},"rotationEnabled":false}'
    run bash "$HOOK" <<< "$(hook_input "$FIXTURES/130k-opus.jsonl" false "sess-wrapper")"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -e "$STATE_DIR/bb-calls" ]
}

# --- P2-1: synthetic zero-usage records must not measure as 0 ---------------

@test "coordinator-handoff: a trailing synthetic zero-usage record does not mask real context" {
    make_bb_stub '{"marking":{},"rotationEnabled":false}'
    run bash "$HOOK" <<< "$(hook_input "$FIXTURES/130k-sonnet-then-synthetic.jsonl" false "sess-synthetic")"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    decision="$(jq -r '.decision' <<<"$output")"
    reason="$(jq -r '.reason' <<<"$output")"
    [ "$decision" = "block" ]
    [[ "$reason" == *"130000"* ]]
}

# --- P2-2: re-entering a band after dropping below threshold must not stay
#     suppressed by a stale band marker. -------------------------------------

@test "coordinator-handoff: dropping below threshold clears the band so climbing back blocks again" {
    make_bb_stub '{"marking":{},"rotationEnabled":false}'
    run bash "$HOOK" <<< "$(hook_input "$FIXTURES/130k-opus.jsonl" false "sess-reentry")"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    decision="$(jq -r '.decision' <<<"$output")"
    [ "$decision" = "block" ]
    first_calls="$(wc -l < "$STATE_DIR/bb-calls")"

    # A /compact-style drop below threshold: silent, and must clear the band.
    run bash "$HOOK" <<< "$(hook_input "$FIXTURES/60k.jsonl" false "sess-reentry")"
    [ "$status" -eq 0 ]
    [ -z "$output" ]

    # Back at 130k in the same session: must NOT be silenced by the old band
    # marker -- bb must be consulted again and the block re-emitted.
    make_bb_stub '{"marking":{},"rotationEnabled":false}'
    run bash "$HOOK" <<< "$(hook_input "$FIXTURES/130k-opus.jsonl" false "sess-reentry")"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    decision="$(jq -r '.decision' <<<"$output")"
    [ "$decision" = "block" ]
    second_calls="$(wc -l < "$STATE_DIR/bb-calls")"
    [ "$second_calls" -gt "$first_calls" ]
}

# --- P2-3: an unreadable band file must not silence the hook permanently ----

@test "coordinator-handoff: an unreadable band file still reaches a determination" {
    if [[ "$(id -u)" -eq 0 ]]; then
        skip "running as root: chmod 000 does not block reads"
    fi
    make_bb_stub '{"marking":{},"rotationEnabled":false}'
    run bash "$HOOK" <<< "$(hook_input "$FIXTURES/130k-opus.jsonl" false "sess-unreadable")"
    [ "$status" -eq 0 ]
    [ -n "$output" ]

    band_file="$STATE_DIR/sess-unreadable.band"
    [ -e "$band_file" ]
    chmod 000 "$band_file"

    make_bb_stub '{"marking":{},"rotationEnabled":false}'
    run bash "$HOOK" <<< "$(hook_input "$FIXTURES/130k-opus.jsonl" false "sess-unreadable")"
    [ "$status" -eq 0 ]
    # Must still reach a determination (a block, here, since the "same band"
    # short-circuit could not be trusted) rather than going silent forever.
    [ -n "$output" ]
    decision="$(jq -r '.decision' <<<"$output")"
    [ "$decision" = "block" ]

    chmod 600 "$band_file"
}

# --- P2-4: total runtime must stay comfortably under the hooks.json timeout -

@test "coordinator-handoff: slow bb calls still finish well under the hooks.json timeout" {
    # Each external call sleeps just under the 1s per-call `timeout` cap
    # (P2-4) -- long enough to give the total elapsed time real weight
    # (unlike every other test's instant stubs), but short enough that
    # `timeout 1` does NOT kill the call. A sleep at or above 1s here would
    # exercise a different path entirely (the call gets killed -> that bb
    # lookup fails -> the hook goes silent by design, per the "a bb timeout
    # is silent" test above) rather than the runtime-budget path this test
    # means to cover. This scenario forces all three external calls in one
    # Stop: status (fractional rotateAt forces a context-window lookup) and
    # the model resolver.
    cat > "$STUB_DIR/bb" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$STATE_DIR/bb-calls"
if [[ "\$1 \$2 \$3" == "handoff coordinator status" ]]; then
    sleep 0.8
    printf '%s\n' '{"marking":{"rotateAt":0.3},"rotationEnabled":true}'
    exit 0
fi
if [[ "\$1 \$2" == "thread list" ]]; then
    printf '%s\n' '[]'
    exit 0
fi
if [[ "\$1 \$2" == "thread context" ]]; then
    sleep 0.8
    printf '%s\n' '{"usage":{"modelContextWindow":200000}}'
    exit 0
fi
exit 1
EOF
    chmod +x "$STUB_DIR/bb"

    start=$(date +%s)
    run bash "$HOOK" <<< "$(hook_input "$FIXTURES/130k-opus.jsonl" false "sess-slowbudget")"
    elapsed=$(( $(date +%s) - start ))

    [ "$status" -eq 0 ]
    # 0.3 x 200000 = 60000: enabled, but 70k tokens past it, so the note path.
    [ "$(jq -r "has(\"systemMessage\")" <<<"$output")" = "true" ]
    [ "$elapsed" -lt 8 ]
}



@test "coordinator-handoff: a coordinator with rotation off is told to enable at the threshold, with no replace and no model" {
    make_bb_stub '{"marking":{"seedTokens":30000},"rotationEnabled":false}'
    run bash "$HOOK" <<< "$(hook_input "$FIXTURES/130k-opus.jsonl" false "sess-block")"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.decision' <<<"$output")" = "block" ]
    reason="$(jq -r '.reason' <<<"$output")"
    [[ "$reason" == *"bb handoff coordinator enable --self --rotate-at 90000"* ]]
    [[ "$reason" != *"--replace "* ]]
    [[ "$reason" != *"--model"* ]]
    [[ "$reason" != *"claude-sonnet"* ]]
}

@test "coordinator-handoff: a seed over half the threshold raises --rotate-at to 2x the seed" {
    make_bb_stub '{"marking":{"seedTokens":55219,"rotateAt":50000},"rotationEnabled":true,"lastDeclineReason":"threshold-below-seed"}'
    run bash "$HOOK" <<< "$(hook_input "$FIXTURES/130k-opus.jsonl" false "sess-seed")"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.decision' <<<"$output")" = "block" ]
    reason="$(jq -r '.reason' <<<"$output")"
    [[ "$reason" == *"enable --self --rotate-at 110438"* ]]
    [[ "$reason" != *"--replace "* ]]
}

@test "coordinator-handoff: rotate-at below 2x the seed is not trusted even when under the threshold" {
    make_bb_stub '{"marking":{"seedTokens":60000,"rotateAt":90000},"rotationEnabled":true}'
    run bash "$HOOK" <<< "$(hook_input "$FIXTURES/105k-sonnet.jsonl" false "sess-below")"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.decision' <<<"$output")" = "block" ]
    [[ "$(jq -r '.reason' <<<"$output")" == *"--rotate-at 120000"* ]]
}

@test "coordinator-handoff: rotate-at at 2x the seed is accepted and stays silent in the first band" {
    make_bb_stub '{"marking":{"seedTokens":50000,"rotateAt":100000},"rotationEnabled":true}'
    run bash "$HOOK" <<< "$(hook_input "$FIXTURES/105k-sonnet.jsonl" false "sess-ok2x")"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "coordinator-handoff: rotation enabled but not rotated a full band later gets a non-blocking note, never a replace" {
    make_bb_stub '{"marking":{"rotateAt":90000},"rotationEnabled":true,"lastDeclineReason":"not-idle"}'
    run bash "$HOOK" <<< "$(hook_input "$FIXTURES/160k-sonnet.jsonl" false "sess-stuck")"
    [ "$status" -eq 0 ]
    [ "$(jq -r 'has("decision")' <<<"$output")" = "false" ]
    msg="$(jq -r '.systemMessage' <<<"$output")"
    [[ "$msg" == *"not-idle"* ]]
    [[ "$msg" != *"--replace "* ]]
}

@test "coordinator-handoff: the vizier thread is never advised" {
    make_bb_stub '{"marking":{"seedTokens":55000},"rotationEnabled":false}'
    cat >> "$STUB_DIR/bb" <<'EOF'
EOF
    sed -i 's|^exit 1$|if [[ "$1 $2" == "thread show" ]]; then printf "%s\\n" "{\\"thread\\":{\\"title\\":\\"Masaq'"'"' \| vizier\\"}}"; exit 0; fi\nexit 1|' "$STUB_DIR/bb"
    run bash "$HOOK" <<< "$(hook_input "$FIXTURES/130k-opus.jsonl" false "sess-vizier")"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "coordinator-handoff: rotation enabled between bands is re-read, not frozen from the first check" {
    COUNTER="$STATE_DIR/status-calls"
    cat > "$STUB_DIR/bb" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$STATE_DIR/bb-calls"
if [[ "\$1 \$2 \$3" == "handoff coordinator status" ]]; then
    n=0
    [[ -f "$COUNTER" ]] && n="\$(cat "$COUNTER")"
    n=\$((n + 1))
    echo "\$n" > "$COUNTER"
    if [[ "\$n" -eq 1 ]]; then
        printf '%s\n' '{"marking":{},"rotationEnabled":false}'
    else
        printf '%s\n' '{"marking":{"rotateAt":90000},"rotationEnabled":true}'
    fi
    exit 0
fi
exit 1
EOF
    chmod +x "$STUB_DIR/bb"

    run bash "$HOOK" <<< "$(hook_input "$FIXTURES/105k-sonnet.jsonl" false "sess-reread")"
    [ "$(jq -r '.decision' <<<"$output")" = "block" ]
    [[ "$(jq -r '.reason' <<<"$output")" == *"coordinator enable"* ]]

    run bash "$HOOK" <<< "$(hook_input "$FIXTURES/160k-sonnet.jsonl" false "sess-reread")"
    [ "$status" -eq 0 ]
    [ "$(jq -r 'has("decision")' <<<"$output")" = "false" ]
    [[ "$(jq -r '.systemMessage' <<<"$output")" == *"no manual handoff"* ]]
}

#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
# Tests for hooks/coordinator-handoff.sh, ported (not copied) from Clavain
# hooks/context-handoff.sh (mk-42j9.12/.13, "coordinators on Sonnet, context
# handoff at 100k").
#
# The hook is a Stop hook. It measures REAL transcript context from the last
# main-chain assistant record (via lib/interpulse-lib.sh's
# _ip_transcript_tokens), and for bb sessions above
# INTERPULSE_COORD_CONTEXT_TOKENS (default 100000):
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
    unset CLAVAIN_COORDINATOR_MODEL_CMD
    unset INTERPULSE_COORD_TIME_BUDGET_S
    # Keep find_clavain_coordinator_model()'s fallback lookup hermetic: point
    # it at locations that do not exist rather than this host's real
    # ~/.claude/plugins files, so these tests never depend on what happens to
    # be installed on the machine running them.
    export CLAVAIN_INSTALLED_FILE="$STATE_DIR/no-such-installed_plugins.json"
    export CLAUDE_PLUGIN_CACHE_ROOT="$STATE_DIR/no-such-cache"

    # coordinator-model.sh stub: resolves to Sonnet, matching the real
    # external script's stdout contract ("<bb-provider> <model>").
    cat > "$STUB_DIR/coordinator-model.sh" <<'EOF'
#!/usr/bin/env bash
printf 'claude-code claude-sonnet-5\n'
EOF
    chmod +x "$STUB_DIR/coordinator-model.sh"
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
    exit ${exit_code}
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

@test "coordinator-handoff: coordinator above threshold on Opus blocks with enable before replace, naming sonnet and 100000" {
    make_bb_stub '{"marking":{},"rotationEnabled":false}'
    run bash "$HOOK" <<< "$(hook_input "$FIXTURES/130k-opus.jsonl" false "sess-block")"
    [ "$status" -eq 0 ]
    decision="$(jq -r '.decision' <<<"$output")"
    reason="$(jq -r '.reason' <<<"$output")"
    [ "$decision" = "block" ]
    [[ "$reason" == *"claude-sonnet-5"* ]]
    [[ "$reason" == *"100000"* ]]
    [[ "$reason" == *"bb handoff --self --to claude-code --model claude-sonnet-5 --replace"* ]]
    [[ "$reason" == *"bb handoff coordinator enable --self --rotate-at 100000"* ]]
    # enable must be listed before --replace: --replace archives the source
    # thread, so a --self command after it would resolve to the archive.
    [[ "$reason" == *"bb handoff coordinator enable --self --rotate-at 100000"*"bb handoff --self --to claude-code --model claude-sonnet-5 --replace"* ]]
}

@test "coordinator-handoff: rotation enabled just past rotate-at (first band) stays silent" {
    make_bb_stub '{"marking":{"rotateAt":90000},"rotationEnabled":true}'
    run bash "$HOOK" <<< "$(hook_input "$FIXTURES/105k-sonnet.jsonl")"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "coordinator-handoff: rotation enabled but still stuck a full band later blocks with a same-model replace" {
    make_bb_stub '{"marking":{"rotateAt":90000},"rotationEnabled":true}'
    run bash "$HOOK" <<< "$(hook_input "$FIXTURES/160k-sonnet.jsonl")"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    decision="$(jq -r '.decision' <<<"$output")"
    reason="$(jq -r '.reason' <<<"$output")"
    [ "$decision" = "block" ]
    [[ "$reason" == *"bb handoff --self --to claude-code --model claude-sonnet-5 --replace"* ]]
    [[ "$reason" != *"coordinator enable"* ]]
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
    [ "$calls" -eq 1 ]
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

@test "coordinator-handoff: a truncated last line does not stop the hook from reading the prior valid record" {
    make_bb_stub '{"marking":{},"rotationEnabled":false}'
    run bash "$HOOK" <<< "$(hook_input "$FIXTURES/truncated.jsonl")"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    decision="$(jq -r '.decision' <<<"$output")"
    [ "$decision" = "block" ]
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
if [[ "\$1 \$2" == "thread list" ]]; then
    printf '%s\n' '[]'
    exit 0
fi
if [[ "\$1 \$2" == "thread context" ]]; then
    printf '%s\n' '{"usage":{"modelContextWindow":200000}}'
    exit 0
fi
exit 1
EOF
    chmod +x "$STUB_DIR/bb"

    run bash "$HOOK" <<< "$(hook_input "$FIXTURES/105k-sonnet.jsonl" false "sess-reread")"
    [ "$status" -eq 0 ]
    decision="$(jq -r '.decision' <<<"$output")"
    reason1="$(jq -r '.reason' <<<"$output")"
    [ "$decision" = "block" ]
    [[ "$reason1" == *"coordinator enable"* ]]
    [[ "$reason1" != *"--replace"* ]]

    run bash "$HOOK" <<< "$(hook_input "$FIXTURES/160k-sonnet.jsonl" false "sess-reread")"
    [ "$status" -eq 0 ]
    decision="$(jq -r '.decision' <<<"$output")"
    reason2="$(jq -r '.reason' <<<"$output")"
    [ "$decision" = "block" ]
    [[ "$reason2" == *"--replace"* ]]
    [[ "$reason2" != *"coordinator enable"* ]]
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
    make_bb_stub '{"marking":null,"rotationEnabled":false}' '[]' 0 1
    run bash "$HOOK" <<< "$(hook_input "$FIXTURES/130k-opus.jsonl" false "sess-childfail")"
    [ "$status" -eq 0 ]
    [ -z "$output" ]

    make_bb_stub '{"marking":null,"rotationEnabled":false}' '[{"id":"thr_c","archivedAt":null}]' 0 0
    run bash "$HOOK" <<< "$(hook_input "$FIXTURES/130k-opus.jsonl" false "sess-childfail")"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    decision="$(jq -r '.decision // empty' <<<"$output")"
    [ "$decision" = "block" ]
}

@test "coordinator-handoff: model resolver missing does not silence a known over-threshold coordinator" {
    rm -f "$STUB_DIR/coordinator-model.sh"
    make_bb_stub '{"marking":{},"rotationEnabled":false}'
    run bash "$HOOK" <<< "$(hook_input "$FIXTURES/130k-opus.jsonl" false "sess-noresolver")"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    decision="$(jq -r '.decision' <<<"$output")"
    reason="$(jq -r '.reason' <<<"$output")"
    [ "$decision" = "block" ]
    [[ "$reason" == *"claude-sonnet-5"* ]]
    [[ "$reason" != *"opus"* ]]
}

# --- P2-7: each fake resolver prints a distinct marker model, so a broken
#     lookup (e.g. one that fell through to the hardcoded fallback instead of
#     actually finding/running the fake root) is caught instead of passing
#     coincidentally. ---------------------------------------------------------

@test "coordinator-handoff: resolver not on PATH is found via a fake installed_plugins.json Clavain root" {
    rm -f "$STUB_DIR/coordinator-model.sh"

    local fake_root="$STATE_DIR/fake-cache/interagency-marketplace/clavain/0.6.999"
    mkdir -p "$fake_root/scripts" "$fake_root/.claude-plugin"
    cat > "$fake_root/scripts/coordinator-model.sh" <<'EOF'
#!/usr/bin/env bash
printf 'claude-code claude-sonnet-5-lookupa\n'
EOF
    chmod +x "$fake_root/scripts/coordinator-model.sh"
    printf '{"name":"clavain","version":"0.6.999"}\n' > "$fake_root/.claude-plugin/plugin.json"

    cat > "$CLAVAIN_INSTALLED_FILE" <<EOF
{
  "version": 2,
  "plugins": {
    "clavain@interagency-marketplace": [
      {"scope": "user", "installPath": "$fake_root", "version": "0.6.999"}
    ]
  }
}
EOF

    make_bb_stub '{"marking":{},"rotationEnabled":false}'
    run bash "$HOOK" <<< "$(hook_input "$FIXTURES/130k-opus.jsonl" false "sess-fakeroot-installed")"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    decision="$(jq -r '.decision' <<<"$output")"
    reason="$(jq -r '.reason' <<<"$output")"
    [ "$decision" = "block" ]
    [[ "$reason" == *"claude-sonnet-5-lookupa"* ]]
}

@test "coordinator-handoff: resolver not on PATH falls back to a plugin-cache glob when installed_plugins.json has no clavain entry" {
    rm -f "$STUB_DIR/coordinator-model.sh"
    # No CLAVAIN_INSTALLED_FILE at all -- lookup #1 must come up empty and
    # fall through to the cache glob, not error out.
    rm -f "$CLAVAIN_INSTALLED_FILE"

    local older="$CLAUDE_PLUGIN_CACHE_ROOT/interagency-marketplace/clavain/0.6.1"
    local newer="$CLAUDE_PLUGIN_CACHE_ROOT/interagency-marketplace/clavain/0.6.999"
    mkdir -p "$older/scripts" "$older/.claude-plugin" "$newer/scripts" "$newer/.claude-plugin"
    printf '#!/usr/bin/env bash\nprintf "claude-code claude-sonnet-5-lookupold\\n"\n' > "$older/scripts/coordinator-model.sh"
    chmod +x "$older/scripts/coordinator-model.sh"
    printf '{"name":"clavain","version":"0.6.1"}\n' > "$older/.claude-plugin/plugin.json"
    touch -d '1 hour ago' "$older" 2>/dev/null || true
    cat > "$newer/scripts/coordinator-model.sh" <<'EOF'
#!/usr/bin/env bash
printf 'claude-code claude-sonnet-5-lookupnew\n'
EOF
    chmod +x "$newer/scripts/coordinator-model.sh"
    printf '{"name":"clavain","version":"0.6.999"}\n' > "$newer/.claude-plugin/plugin.json"
    touch "$newer"   # unambiguously the most recently modified match

    make_bb_stub '{"marking":{},"rotationEnabled":false}'
    run bash "$HOOK" <<< "$(hook_input "$FIXTURES/130k-opus.jsonl" false "sess-fakeroot-cache")"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    decision="$(jq -r '.decision' <<<"$output")"
    reason="$(jq -r '.reason' <<<"$output")"
    [ "$decision" = "block" ]
    [[ "$reason" == *"claude-sonnet-5-lookupnew"* ]]
    [[ "$reason" != *"lookupold"* ]]
}

@test "coordinator-handoff: model resolver returning Opus is never honored" {
    cat > "$STUB_DIR/coordinator-model.sh" <<'EOF'
#!/usr/bin/env bash
printf 'claude-code claude-opus-5-5\n'
EOF
    chmod +x "$STUB_DIR/coordinator-model.sh"
    make_bb_stub '{"marking":{},"rotationEnabled":false}'
    run bash "$HOOK" <<< "$(hook_input "$FIXTURES/130k-opus.jsonl" false "sess-refuseopus")"
    [ "$status" -eq 0 ]
    reason="$(jq -r '.reason' <<<"$output")"
    [[ "$reason" == *"claude-sonnet-5"* ]]
    [[ "$reason" != *"claude-opus-5-5"* ]]
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

@test "coordinator-handoff: slow bb/resolver calls still finish well under the hooks.json timeout" {
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
    cat > "$STUB_DIR/coordinator-model.sh" <<'EOF'
#!/usr/bin/env bash
sleep 0.8
printf 'claude-code claude-sonnet-5\n'
EOF
    chmod +x "$STUB_DIR/coordinator-model.sh"

    start=$(date +%s)
    run bash "$HOOK" <<< "$(hook_input "$FIXTURES/130k-opus.jsonl" false "sess-slowbudget")"
    elapsed=$(( $(date +%s) - start ))

    [ "$status" -eq 0 ]
    [ -n "$output" ]
    decision="$(jq -r '.decision' <<<"$output")"
    [ "$decision" = "block" ]
    [ "$elapsed" -lt 8 ]
}

# --- P3: resolver output allowlist (injection / unknown provider) ----------

@test "coordinator-handoff: resolver output containing shell metacharacters falls back to the hardcoded model" {
    cat > "$STUB_DIR/coordinator-model.sh" <<'EOF'
#!/usr/bin/env bash
printf 'claude-code claude-sonnet-5; rm -rf /\n'
EOF
    chmod +x "$STUB_DIR/coordinator-model.sh"
    make_bb_stub '{"marking":{},"rotationEnabled":false}'
    run bash "$HOOK" <<< "$(hook_input "$FIXTURES/130k-opus.jsonl" false "sess-injectmodel")"
    [ "$status" -eq 0 ]
    reason="$(jq -r '.reason' <<<"$output")"
    [[ "$reason" == *"bb handoff --self --to claude-code --model claude-sonnet-5 --replace"* ]]
    [[ "$reason" != *"rm -rf"* ]]
    [[ "$reason" != *";"* ]]
}

@test "coordinator-handoff: an unknown provider from the resolver falls back to claude-code" {
    cat > "$STUB_DIR/coordinator-model.sh" <<'EOF'
#!/usr/bin/env bash
printf 'some-other-provider claude-sonnet-5\n'
EOF
    chmod +x "$STUB_DIR/coordinator-model.sh"
    make_bb_stub '{"marking":{},"rotationEnabled":false}'
    run bash "$HOOK" <<< "$(hook_input "$FIXTURES/130k-opus.jsonl" false "sess-unknownprovider")"
    [ "$status" -eq 0 ]
    reason="$(jq -r '.reason' <<<"$output")"
    [[ "$reason" == *"--to claude-code --model claude-sonnet-5"* ]]
    [[ "$reason" != *"some-other-provider"* ]]
}

# --- P3: dated-snapshot model suffix must not defeat the MODEL_OK compare ---

@test "coordinator-handoff: rotation-ok coordinator on a dated model snapshot still matches the resolver's undated alias" {
    # Same shape as "rotation enabled just past rotate-at (first band) stays
    # silent", but the transcript records a dated snapshot id
    # (claude-sonnet-5-20260315) while the resolver returns the undated alias
    # (claude-sonnet-5). Without suffix normalization MODEL_OK would be false,
    # forcing a spurious --replace even though rotation is otherwise fine.
    make_bb_stub '{"marking":{"rotateAt":90000},"rotationEnabled":true}'
    run bash "$HOOK" <<< "$(hook_input "$FIXTURES/105k-sonnet-dated.jsonl")"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

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

@test "coordinator-handoff: resolver not on PATH is found via a fake installed_plugins.json Clavain root" {
    rm -f "$STUB_DIR/coordinator-model.sh"

    local fake_root="$STATE_DIR/fake-cache/interagency-marketplace/clavain/0.6.999"
    mkdir -p "$fake_root/scripts" "$fake_root/.claude-plugin"
    cat > "$fake_root/scripts/coordinator-model.sh" <<'EOF'
#!/usr/bin/env bash
printf 'claude-code claude-sonnet-5\n'
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
    [[ "$reason" == *"claude-sonnet-5"* ]]
}

@test "coordinator-handoff: resolver not on PATH falls back to a plugin-cache glob when installed_plugins.json has no clavain entry" {
    rm -f "$STUB_DIR/coordinator-model.sh"
    # No CLAVAIN_INSTALLED_FILE at all -- lookup #1 must come up empty and
    # fall through to the cache glob, not error out.
    rm -f "$CLAVAIN_INSTALLED_FILE"

    local older="$CLAUDE_PLUGIN_CACHE_ROOT/interagency-marketplace/clavain/0.6.1"
    local newer="$CLAUDE_PLUGIN_CACHE_ROOT/interagency-marketplace/clavain/0.6.999"
    mkdir -p "$older/scripts" "$newer/scripts"
    printf '#!/usr/bin/env bash\nprintf "claude-code claude-opus-5-5\\n"\n' > "$older/scripts/coordinator-model.sh"
    chmod +x "$older/scripts/coordinator-model.sh"
    touch -d '1 hour ago' "$older" 2>/dev/null || true
    cat > "$newer/scripts/coordinator-model.sh" <<'EOF'
#!/usr/bin/env bash
printf 'claude-code claude-sonnet-5\n'
EOF
    chmod +x "$newer/scripts/coordinator-model.sh"
    touch "$newer"   # unambiguously the most recently modified match

    make_bb_stub '{"marking":{},"rotationEnabled":false}'
    run bash "$HOOK" <<< "$(hook_input "$FIXTURES/130k-opus.jsonl" false "sess-fakeroot-cache")"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    decision="$(jq -r '.decision' <<<"$output")"
    reason="$(jq -r '.reason' <<<"$output")"
    [ "$decision" = "block" ]
    [[ "$reason" == *"claude-sonnet-5"* ]]
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

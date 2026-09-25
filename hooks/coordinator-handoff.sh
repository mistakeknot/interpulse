#!/usr/bin/env bash
# Stop hook: coordinator-handoff — nudge bb coordinator/worker threads to
# hand off once REAL transcript context crosses an absolute token threshold.
#
# Ported (not copied) from Clavain hooks/context-handoff.sh (mk-42j9.12/.13,
# "coordinators on Sonnet, context handoff at 100k"), adapted to interpulse's
# conventions and hardened against a fail-open-state-drift finding from that
# port's own security review (see "STATE PERSISTENCE" below).
#
# Context measure: the last main-chain (isSidechain=false, type=assistant)
# record's input_tokens + cache_creation_input_tokens + cache_read_input_tokens,
# via lib/interpulse-lib.sh's _ip_transcript_tokens (bounded 256 KiB tail
# read, shared with hooks/context-monitor.sh's PostToolUse extension so both
# mechanisms measure and threshold on the exact same absolute number).
#
# This is an ABSOLUTE threshold (default 100000 tokens), not a percentage of
# the model's context window: context-monitor.sh's existing heuristic
# Yellow/Orange/Red bands are a percentage of window size and fire far too
# late on 1M-context models (100k tokens is 10% there, not the "context
# nearly exhausted" that 85% implies elsewhere). This hook and the
# context-monitor.sh extension deliberately do not scale with window size.
#
# Settings:
#   INTERPULSE_COORD_CONTEXT_TOKENS  threshold, default 100000
#   INTERPULSE_COORD_HOOK=off        disables the hook entirely
#   INTERPULSE_COORD_STATE_DIR       per-session band-throttle dir (default
#                                    ~/.interpulse/coordinator-handoff)
#   INTERPULSE_COORD_CONTEXT_WINDOW  explicit override for the window used to
#                                    convert a fractional bb rotateAt (e.g.
#                                    0.3) into a token count. Unset by
#                                    default: read live from
#                                    `bb thread context "$BB_THREAD_ID" --json`
#                                    fresh every time this hook does a bb
#                                    lookup. If unavailable, a fractional
#                                    rotateAt is treated as NOT satisfying the
#                                    rotation-ok check (fail toward emitting
#                                    the directive, never toward silence).
#   CLAVAIN_COORDINATOR_MODEL_CMD    name/path of the external coordinator
#                                    model resolver, default
#                                    "coordinator-model.sh" (resolved via
#                                    `command -v`). This script is Clavain's
#                                    scripts/coordinator-model.sh -- it STAYS
#                                    in Clavain; this hook calls it as an
#                                    external command and never reimplements
#                                    its `ic route dispatch --role=coordination`
#                                    resolution logic. On a real install,
#                                    "coordinator-model.sh" is usually NOT on
#                                    PATH (Clavain ships it under
#                                    scripts/, not bin/), so when this
#                                    variable is unset and the plain name
#                                    does not resolve via `command -v`, this
#                                    hook falls back to locating Clavain's
#                                    installed plugin root the same way
#                                    Clavain's own hooks/release-canary-check.sh
#                                    does (installed_plugins.json's
#                                    "clavain@<marketplace>" installPath),
#                                    then interline's scripts/statusline.sh
#                                    glob over the plugin cache
#                                    (~/.claude/plugins/cache/*/clavain/*,
#                                    most recently modified) if that lookup
#                                    comes up empty -- see
#                                    find_clavain_coordinator_model() below.
#                                    If neither locates a usable script, or
#                                    the resolver can't be found or fails,
#                                    this hook falls back to the same
#                                    hardcoded pair coordinator-model.sh
#                                    itself would print on failure
#                                    ("claude-code claude-sonnet-5") -- see
#                                    resolve_coordinator_model() below. An
#                                    Opus-class result is never honored for
#                                    this role, from any path.
#
# STATE PERSISTENCE (fail-open-state-drift hardening):
#
#   Band throttle (at most one bb consult per 25k-token band per session):
#   the band file is written ONLY after this Stop reaches a fully determined
#   outcome (silence because rotation is genuinely ok, a coordinator block,
#   or a worker advisory) -- never before or during the bb lookups that
#   outcome depends on.
#
#   The Clavain original wrote the band file BEFORE any bb lookup, as a
#   throttle optimization. That means a bb failure/timeout partway through
#   this Stop's checks (which still exits 0, silent, by design) left the
#   band file claiming the band HAD been checked -- so a real coordinator
#   sitting well over threshold got no directive for the rest of that
#   25k-token band, purely because bb hiccuped once. That is exactly a
#   fail-open path that swallows an error and silently defaults to "handled"
#   when it could not actually determine that. Every bb-lookup failure path
#   below `exit`s before the band file is ever touched, so the very next
#   Stop (even one token later, same band) retries against bb instead of
#   trusting a determination that never completed.
#
#   Model resolution (resolve_coordinator_model) never contributes to this
#   either: it always returns a usable provider/model pair (falling back to
#   the hardcoded Sonnet pair rather than failing), so a coordinator already
#   known to be over threshold is never silenced just because the external
#   resolver command was missing or crashed.
#
#   Nothing beyond the plain band integer is cached across bands. Rotation
#   state, coordinator/worker status and the live context window are always
#   re-read fresh from bb the moment a NEW band is reached -- there is no
#   session-scoped cache of any of those that could drift stale (matches
#   Clavain's P2-3 fix: a per-session cache previously froze this state from
#   the first check of the session).
#
#   If the state directory itself can't be created/written (disk full,
#   permissions), this hook does NOT abort silently -- STATE_WRITABLE=false
#   lets every subsequent Stop still perform the full, fresh determination
#   (just without the band throttle optimization). Aborting the whole hook
#   on a filesystem hiccup would itself be a silent "under threshold" default
#   for a condition (coordinator over threshold) this hook never actually
#   re-checked.
#
# Rotation trust (Clavain P2-2): bb declines to rotate a thread below ~2x its
# marking's seedTokens (and on hold/cooldown/generation caps), so
# "rotationEnabled at or under the threshold" only earns silence for the
# FIRST 25k-token band above rotate-at. A later Stop still at or past
# rotate-at plus one band means bb evidently did not rotate, and this hook
# emits a --replace handoff directive instead of a redundant `coordinator
# enable`. Nothing here persists that trust beyond the current band's fresh
# bb read (Clavain P2-3): the "first band" judgment is recomputed from
# CONTEXT_TOKENS and a freshly re-read ROTATE_EFFECTIVE every single time,
# never cached.
#
# Command order (Clavain P2-1): `enable` is always listed before `--replace`
# when both are needed -- `--replace` archives the source thread, so a
# `--self` command issued after it resolves to the archived source, not the
# successor.
#
# Coordinator: blocking `{"decision":"block","reason":...}`.
# Worker: advisory `{"systemMessage":...}`, never a block.
# Silent (exit 0, no output) on: jq missing, INTERPULSE_COORD_HOOK=off,
# no BB_THREAD_ID, stop_hook_active, below threshold, a same-band repeat
# that already reached a determined outcome, or any bb lookup
# failure/timeout (which never persists band state -- see above).
set -uo pipefail
trap 'exit 0' ERR

SCRIPT_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
# shellcheck source=lib/interpulse-lib.sh
source "$SCRIPT_DIR/../lib/interpulse-lib.sh"

command -v jq >/dev/null 2>&1 || exit 0

[[ "${INTERPULSE_COORD_HOOK:-}" == "off" ]] && exit 0

# Not a bb session: nothing to hand off.
[[ -n "${BB_THREAD_ID:-}" ]] || exit 0

INPUT="$(cat)"

STOP_ACTIVE="$(jq -r '.stop_hook_active // false' <<<"$INPUT" 2>/dev/null)" || exit 0
[[ "$STOP_ACTIVE" == "true" ]] && exit 0

SESSION_ID="$(jq -r '.session_id // "unknown"' <<<"$INPUT" 2>/dev/null)" || exit 0
TRANSCRIPT="$(_ip_transcript_path "$INPUT")"
[[ -n "$TRANSCRIPT" && -f "$TRANSCRIPT" ]] || exit 0

THRESHOLD="${INTERPULSE_COORD_CONTEXT_TOKENS:-100000}"
[[ "$THRESHOLD" =~ ^[0-9]+$ ]] || exit 0

STATE_DIR="${INTERPULSE_COORD_STATE_DIR:-$HOME/.interpulse/coordinator-handoff}"
STATE_WRITABLE=true
mkdir -p "$STATE_DIR" 2>/dev/null || STATE_WRITABLE=false
SAFE_SID="$(printf '%s' "$SESSION_ID" | tr '/:' '__')"
BAND_FILE="$STATE_DIR/${SAFE_SID}.band"

# --- Context measure (shared with context-monitor.sh's absolute tracking) ---
RESULT="$(_ip_transcript_tokens "$TRANSCRIPT")"
CONTEXT_TOKENS="${RESULT%% *}"
MODEL="${RESULT#* }"

[[ "$CONTEXT_TOKENS" =~ ^[0-9]+$ ]] || exit 0
(( CONTEXT_TOKENS < THRESHOLD )) && exit 0

# --- Band throttle: read only (write deferred until a real outcome exists) --
band=$(( CONTEXT_TOKENS / 25000 ))
PREV_BAND=""
[[ -f "$BAND_FILE" ]] && PREV_BAND="$(cat "$BAND_FILE" 2>/dev/null)"
[[ "$PREV_BAND" == "$band" ]] && exit 0

_persist_band() {
    [[ "$STATE_WRITABLE" == true ]] || return 0
    printf '%s' "$band" > "$BAND_FILE" 2>/dev/null || true
}

# Locate an installed Clavain's scripts/coordinator-model.sh when the plain
# name isn't on PATH. Established pattern, not invented here:
#   1. installed_plugins.json's "clavain@<marketplace>" installPath -- the
#      same lookup Clavain's own hooks/release-canary-check.sh does against
#      that file (installPath existence + a parseable plugin.json).
#   2. Failing that, the plugin-cache glob interline's scripts/statusline.sh
#      already uses to find Clavain's version
#      (~/.claude/plugins/cache/*/clavain/*), taking the most recently
#      modified match.
# Overridable for tests via CLAVAIN_INSTALLED_FILE (matches
# release-canary-check.sh's own override name) and CLAUDE_PLUGIN_CACHE_ROOT
# (matches scripts/check-install-updates.sh's override name). Prints nothing
# and returns non-zero if no usable coordinator-model.sh is found.
find_clavain_coordinator_model() {
    local installed_file="${CLAVAIN_INSTALLED_FILE:-$HOME/.claude/plugins/installed_plugins.json}"
    local cache_root="${CLAUDE_PLUGIN_CACHE_ROOT:-$HOME/.claude/plugins/cache}"
    local root="" candidate

    if command -v jq >/dev/null 2>&1 && [[ -f "$installed_file" ]]; then
        root="$(jq -r '
            .plugins // {} | to_entries[]
            | select(.key | test("^clavain@"))
            | .value[0].installPath // empty
        ' "$installed_file" 2>/dev/null | head -1)" || root=""
    fi

    if [[ -z "$root" || ! -d "$root" ]]; then
        root=""
        for candidate in $(ls -td "$cache_root"/*/clavain/* 2>/dev/null); do
            [[ -d "$candidate" ]] || continue
            root="$candidate"
            break
        done
    fi

    [[ -n "$root" && -f "$root/scripts/coordinator-model.sh" ]] || return 1
    printf '%s\n' "$root/scripts/coordinator-model.sh"
}

# Resolve the coordinator model by calling Clavain's scripts/coordinator-model.sh
# as an external command -- never reimplemented here. Always returns a usable
# "<provider> <model>" pair; never leaves the caller without one, and never
# an Opus-class model.
resolve_coordinator_model() {
    local cmd="${CLAVAIN_COORDINATOR_MODEL_CMD:-}"
    local resolved="" provider model

    if [[ -z "$cmd" ]]; then
        cmd="coordinator-model.sh"
        if ! command -v "$cmd" >/dev/null 2>&1; then
            local found=""
            found="$(find_clavain_coordinator_model)" || found=""
            [[ -n "$found" ]] && cmd="$found"
        fi
    fi

    if command -v "$cmd" >/dev/null 2>&1; then
        if command -v timeout >/dev/null 2>&1; then
            resolved="$(timeout 2 "$cmd" 2>/dev/null)" || resolved=""
        else
            resolved="$("$cmd" 2>/dev/null)" || resolved=""
        fi
    fi

    provider="${resolved%% *}"
    model="${resolved#* }"
    if [[ -z "$resolved" || "$provider" == "$resolved" || -z "$provider" || -z "$model" ]]; then
        # coordinator-model.sh not on PATH, or it failed/produced unusable
        # output: fail soft to the exact fallback pair it documents for its
        # own error paths. This never blocks a directive on the resolver
        # being unavailable.
        provider="claude-code"
        model="claude-sonnet-5"
    fi

    # Defense in depth: this role never runs Opus, regardless of what a
    # broken or misconfigured external resolver printed. coordinator-model.sh
    # already refuses Opus internally; this is a second, independent check
    # against forwarding one anyway.
    case "${model,,}" in
        *opus*) provider="claude-code"; model="claude-sonnet-5" ;;
    esac

    printf '%s %s\n' "$provider" "$model"
}

# --- Who counts as a coordinator (bb consulted fresh, once per band) ---
# Every bb-lookup failure below exits WITHOUT calling _persist_band, so the
# band file never claims this Stop reached a determination it didn't.
command -v bb >/dev/null 2>&1 || exit 0
TIMEOUT_CMD=()
command -v timeout >/dev/null 2>&1 && TIMEOUT_CMD=(timeout 2)

IS_COORDINATOR="false"
ROTATION_ENABLED="false"
ROTATE_AT=""

STATUS_JSON="$("${TIMEOUT_CMD[@]}" bb handoff coordinator status --self --json 2>/dev/null)" || exit 0
[[ -n "$STATUS_JSON" ]] || exit 0
MARKED="$(jq -r 'if .marking == null then "false" else "true" end' <<<"$STATUS_JSON" 2>/dev/null)" || exit 0

if [[ "$MARKED" == "true" ]]; then
    IS_COORDINATOR="true"
    ROTATION_ENABLED="$(jq -r '.rotationEnabled // false' <<<"$STATUS_JSON" 2>/dev/null)"
    ROTATE_AT="$(jq -r '.marking.rotateAt // empty' <<<"$STATUS_JSON" 2>/dev/null)"
else
    # --include-hidden: a hidden child still makes this thread a coordinator.
    CHILDREN_JSON="$("${TIMEOUT_CMD[@]}" bb thread list --parent-thread "$BB_THREAD_ID" --include-hidden --json 2>/dev/null)" || exit 0
    [[ -n "$CHILDREN_JSON" ]] || exit 0
    CHILD_COUNT="$(jq '[.[] | select(.archivedAt == null)] | length' <<<"$CHILDREN_JSON" 2>/dev/null)" || exit 0
    [[ "$CHILD_COUNT" =~ ^[0-9]+$ ]] || exit 0
    (( CHILD_COUNT > 0 )) && IS_COORDINATOR="true"
fi

if [[ "$IS_COORDINATOR" == "true" ]]; then
    # Effective rotate-at in tokens: a fraction in [0,1) is scaled by the
    # thread's live context window (bb's own fraction/absolute split is
    # `<1`, not `<=1`); anything else is treated as an absolute token count.
    ROTATE_EFFECTIVE=-1
    if [[ "$ROTATION_ENABLED" == "true" && -n "$ROTATE_AT" && "$ROTATE_AT" != "null" ]]; then
        IS_FRACTION="$(awk -v r="$ROTATE_AT" 'BEGIN{ print (r+0>0 && r+0<1) ? "yes" : "no" }' 2>/dev/null)" || IS_FRACTION="no"

        if [[ "$IS_FRACTION" == "yes" ]]; then
            WINDOW="${INTERPULSE_COORD_CONTEXT_WINDOW:-}"
            if [[ -z "$WINDOW" ]]; then
                # `|| true`: a nonzero exit here (bb failure/timeout) falls
                # through to "window unknown" below, never toward silence.
                CONTEXT_JSON="$("${TIMEOUT_CMD[@]}" bb thread context "$BB_THREAD_ID" --json 2>/dev/null)" || true
                WINDOW="$(jq -r '.usage.modelContextWindow // empty' <<<"$CONTEXT_JSON" 2>/dev/null)" || true
                [[ "$WINDOW" =~ ^[0-9]+$ ]] || WINDOW=""
            fi

            if [[ "$WINDOW" =~ ^[0-9]+$ ]]; then
                ROTATE_EFFECTIVE="$(awk -v r="$ROTATE_AT" -v w="$WINDOW" 'BEGIN{ printf "%d", r*w }' 2>/dev/null)"
            else
                # Window unknown: fail toward emitting the directive.
                ROTATE_EFFECTIVE=-1
            fi
        else
            ROTATE_EFFECTIVE="$(awk -v r="$ROTATE_AT" 'BEGIN{ printf "%d", r }' 2>/dev/null)"
        fi
        [[ "$ROTATE_EFFECTIVE" =~ ^-?[0-9]+$ ]] || ROTATE_EFFECTIVE=-1
    fi

    read -r RESOLVED_PROVIDER RESOLVED_MODEL < <(resolve_coordinator_model)

    # Rotation is "configured" once bb reports it enabled at or under this
    # hook's own threshold. Configured alone isn't trusted: bb can decline to
    # actually rotate (seed guard, hold, cooldown, generation cap). Silence
    # is earned only in the FIRST band above rotate-at (freshly computed
    # every time -- nothing here is cached beyond this Stop's own read).
    ROTATION_CONFIGURED="false"
    if [[ "$ROTATION_ENABLED" == "true" && "$ROTATE_EFFECTIVE" -ge 0 && "$ROTATE_EFFECTIVE" -le "$THRESHOLD" ]]; then
        ROTATION_CONFIGURED="true"
    fi

    ROTATION_OK="false"
    ROTATION_STUCK="false"
    if [[ "$ROTATION_CONFIGURED" == "true" ]]; then
        TOKENS_SINCE_ROTATE=$(( CONTEXT_TOKENS - ROTATE_EFFECTIVE ))
        if (( TOKENS_SINCE_ROTATE < 25000 )); then
            ROTATION_OK="true"
        else
            ROTATION_STUCK="true"
        fi
    fi

    MODEL_OK="false"
    [[ "$MODEL" == "$RESOLVED_MODEL" ]] && MODEL_OK="true"

    if [[ "$ROTATION_OK" == "true" && "$MODEL_OK" == "true" ]]; then
        _persist_band
        exit 0
    fi

    # `enable` (if needed) always comes before `--replace` (if needed):
    # `--replace` archives the source, so a `--self` command issued after it
    # resolves to the archived source, not the successor (Clavain P2-1).
    NEED_ENABLE="false"
    NEED_REPLACE="false"
    if [[ "$ROTATION_OK" != "true" ]]; then
        if [[ "$ROTATION_STUCK" == "true" ]]; then
            # Already enabled correctly but bb didn't rotate: re-issuing the
            # same `enable` is redundant. Force the handoff instead.
            NEED_REPLACE="true"
        else
            NEED_ENABLE="true"
            [[ "$MODEL_OK" != "true" ]] && NEED_REPLACE="true"
        fi
    else
        [[ "$MODEL_OK" != "true" ]] && NEED_REPLACE="true"
    fi

    CMDS=""
    if [[ "$NEED_ENABLE" == "true" ]]; then
        CMDS="${CMDS}"$'\n'"  bb handoff coordinator enable --self --rotate-at ${THRESHOLD}"
    fi
    if [[ "$NEED_REPLACE" == "true" ]]; then
        CMDS="${CMDS}"$'\n'"  bb handoff --self --to ${RESOLVED_PROVIDER} --model ${RESOLVED_MODEL} --replace"
    fi

    REASON="Context handoff: this coordinator thread is at ~${CONTEXT_TOKENS} tokens of context (threshold ${THRESHOLD}). Run:${CMDS}"
    _persist_band
    jq -n --arg reason "$REASON" '{"decision":"block","reason":$reason}'
    exit 0
fi

REASON="Context handoff (advisory): this thread is at ~${CONTEXT_TOKENS} tokens of context (threshold ${THRESHOLD}). Consider handing off, e.g. bb handoff --self --to <provider> --model <model> --replace"
_persist_band
jq -n --arg msg "$REASON" '{"systemMessage":$msg}'
exit 0

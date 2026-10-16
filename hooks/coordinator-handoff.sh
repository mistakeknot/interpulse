#!/usr/bin/env bash
# Stop hook: coordinator-handoff — nudge bb coordinator/worker threads to
# hand off once REAL transcript context crosses an absolute token threshold.
#
# Ported (not copied) from Clavain hooks/context-handoff.sh (bead mk-42j9.13),
# adapted to interpulse's
# conventions and hardened against a fail-open-state-drift finding from that
# port's own security review (see "STATE PERSISTENCE" below).
#
# Context measure: the last main-chain (isSidechain=false, type=assistant,
# message.model != "<synthetic>") record's
# input_tokens + cache_creation_input_tokens + cache_read_input_tokens,
# via lib/interpulse-lib.sh's _ip_transcript_tokens (bounded 256 KiB tail
# read, shared with hooks/context-monitor.sh's PostToolUse extension so both
# mechanisms measure and threshold on the exact same absolute number).
# Synthetic records (Claude Code's own zero-usage markers for rate-limit/
# OAuth-expiry/similar turns, matching scripts/burn-report.py:83's skip) are
# excluded so a turn that ends on one of those doesn't measure as 0 and go
# silent.
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
#                                    Full order: CLAVAIN_COORDINATOR_MODEL_CMD
#                                    override -> PATH -> installed_plugins.json
#                                    -> plugin cache -> hardcoded Sonnet.
#                                    If neither locates a usable script, or
#                                    the resolver can't be found or fails,
#                                    this hook falls back to the same
#                                    hardcoded pair coordinator-model.sh
#                                    itself would print on failure
#                                    ("claude-code claude-sonnet-5") -- see
#                                    resolve_coordinator_model() below. An
#                                    Opus-class result is never honored for
#                                    this role, from any path; the resolver's
#                                    provider/model output is also allowlist-
#                                    validated (see _ip_valid_provider /
#                                    _ip_valid_model below) before it is ever
#                                    used to build a "Run:" command.
#
# STATE PERSISTENCE (fail-open-state-drift hardening):
#
#   Band throttle (at most one bb consult per 25k-token band per session):
#   the band file is written ONLY after this Stop reaches a fully determined
#   outcome (silence because rotation is genuinely ok, a coordinator block,
#   or a worker advisory) -- never before or during the bb lookups that
#   outcome depends on. The band file is also DELETED whenever context is
#   measured below the threshold (P2-2): otherwise a session that dropped
#   below threshold (e.g. via /compact) and later climbed back into the same
#   band number would find that band already marked and stay silent, losing
#   the required block for up to 25k tokens.
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
#   Reading the band file back (P2-3) never trusts a bare `&&`-chained
#   command substitution: `cat` on an unreadable file (foreign-owned state
#   dir, bad restore, permission change) must not trip the script-wide ERR
#   trap and silence the hook permanently -- see the PREV_BAND read below.
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
# Runtime budget (P2-4): each external call (bb, the resolver) is capped at
# 1s via `timeout`, and an overall elapsed-time check skips the remaining
# OPTIONAL lookups (the live context-window read, the external resolver)
# once this Stop has already run for about 6s, falling back to their
# documented safe defaults ("window unknown" / hardcoded Sonnet) instead.
# hooks.json's Stop entry timeout is 10s, giving headroom above the ~4s
# worst case (status + list/context + resolver, each capped at 1s).
#
# Coordinator: blocking `{"decision":"block","reason":...}`.
# Worker: advisory `{"systemMessage":...}`, never a block.
# Silent (exit 0, no output) on: jq missing, a headless/`claude -p` session
# or a dispatched child that inherited a coordinator's BB_THREAD_ID (see
# _ip_is_headless below), INTERPULSE_COORD_HOOK=off,
# no BB_THREAD_ID, stop_hook_active, below threshold, a same-band repeat
# that already reached a determined outcome, or any bb lookup
# failure/timeout (which never persists band state -- see above).
#
# Known limits: requires bash >= 4.4 (`${x,,}`) and coreutils `timeout`
# (stock macOS bash/coreutils are not supported -- the hook exits 1 there
# and never enforces); PostToolUse's `additionalContext` output shape in
# hooks/context-monitor.sh is unchanged by this hardening pass.
set -uo pipefail
trap 'exit 0' ERR

HOOK_START_S=$(date +%s)
# Optional-call time budget (P2-4): once this Stop has run this long,
# remaining OPTIONAL lookups (the live context-window read, the external
# resolver) are skipped in favor of their documented safe defaults, instead
# of risking the hooks.json Stop timeout and losing the whole determination
# (including a real block) to a slow/hung external process. Overridable only
# for tests.
_ip_elapsed_over_budget() {
    local budget="${INTERPULSE_COORD_TIME_BUDGET_S:-6}"
    local now
    now=$(date +%s) || return 1
    (( now - HOOK_START_S >= budget ))
}

SCRIPT_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
# shellcheck source=lib/interpulse-lib.sh
source "$SCRIPT_DIR/../lib/interpulse-lib.sh"

command -v jq >/dev/null 2>&1 || exit 0

[[ "${INTERPULSE_COORD_HOOK:-}" == "off" ]] && exit 0

# --- Headless / dispatched-child guard (P1-1) ---------------
# A Stop hook's decision:"block" is injected as a NEW PROMPT TURN. In a
# headless `claude -p`/`--print` run that injected turn's reply REPLACES the
# reply the caller actually asked for (observed live 2026-07-20: a scripted
# data pass lost 44/45 responses to hook chatter).
#
# Separately: Clavain's scripts/dispatch.sh claude backend runs `claude -p`
# with the parent's environment, and nothing unsets BB_THREAD_ID, so a
# dispatched validation/review child inherits its coordinator PARENT's
# thread ID. Without this guard, that child's own Stop could resolve (via
# `bb handoff coordinator status --self`) to the marked PARENT thread and,
# if the block's "Run: ... --replace" is obeyed, archive the live
# coordinator. The headless check below covers this: a dispatched child is
# itself a `claude -p` process, so it is caught the same way.
#
# This is a self-contained port of Clavain hooks/lib-headless.sh's
# clavain_is_headless -- deliberately NOT sourced from an installed Clavain
# (this hook never reimplements or imports Clavain internals beyond calling
# scripts/coordinator-model.sh as an external command; see the
# CLAVAIN_COORDINATOR_MODEL_CMD comment above). Walks up to 8 process
# ancestors looking for a `claude` process; if found running as
# `-p`/`--print`, this session is headless. Fails OPEN (returns 1, "not
# headless") on any `ps` error, so a detector bug never suppresses the
# interactive block this hook exists to emit.
#
# A cheaper same-session check (comparing the Stop payload's session against
# whatever `bb thread context --self` reports) was considered too, but this
# hook has no bb call that is unconditionally made before the headless
# check -- adding one here would cost an extra bb round trip on every single
# Stop, not just above threshold, which this hook's whole design (bb
# consulted only once we already know we're above threshold) avoids. Absent
# a documented session-id field on an already-budgeted bb call, this stays
# a ps-only check.
_ip_is_headless() {
    local pid=$$ args exe
    local _i
    for _i in 1 2 3 4 5 6 7 8; do
        pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')" || return 1
        [[ -z "$pid" || "$pid" == "0" || "$pid" == "1" ]] && return 1
        args="$(ps -o args= -p "$pid" 2>/dev/null)" || return 1
        # Match the executable's basename only, so a wrapper shell whose
        # command line merely mentions "claude" (a plugin path) is skipped
        # and the walk continues to the real claude ancestor.
        exe="${args%% *}"
        exe="${exe##*/}"
        if [[ "$exe" == "claude" ]]; then
            case " $args " in
                *" -p "*|*" --print "*) return 0 ;;
            esac
            return 1
        fi
    done
    return 1
}
_ip_is_headless && exit 0

# Not a bb session: nothing to hand off.
[[ -n "${BB_THREAD_ID:-}" ]] || exit 0

INPUT="$(cat)"

STOP_ACTIVE="$(jq -r '.stop_hook_active // false' <<<"$INPUT" 2>/dev/null)" || exit 0
[[ "$STOP_ACTIVE" == "true" ]] && exit 0

TRANSCRIPT="$(_ip_transcript_path "$INPUT")"
[[ -n "$TRANSCRIPT" && -f "$TRANSCRIPT" ]] || exit 0

SESSION_ID="$(jq -r '.session_id // empty' <<<"$INPUT" 2>/dev/null)" || exit 0
if [[ -z "$SESSION_ID" ]]; then
    # Missing session_id (P3): the literal "unknown" is shared by every such
    # session, so they'd all throttle each other's band file. Hash the
    # transcript path instead -- distinct transcripts get distinct keys.
    SESSION_ID="unknown-$(printf '%s' "$TRANSCRIPT" | cksum 2>/dev/null | cut -d' ' -f1)"
    [[ -n "$SESSION_ID" && "$SESSION_ID" != "unknown-" ]] || SESSION_ID="unknown"
fi

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
if (( CONTEXT_TOKENS < THRESHOLD )); then
    # P2-2: clear any stale band marker so re-entering a later band (e.g.
    # after a /compact drop and climbing back up) isn't suppressed by a
    # band number that was already "handled" before the drop.
    [[ "$STATE_WRITABLE" == true ]] && rm -f "$BAND_FILE" 2>/dev/null
    exit 0
fi

# --- Band throttle: read only (write deferred until a real outcome exists) --
band=$(( CONTEXT_TOKENS / 25000 ))
PREV_BAND=""
if [[ -f "$BAND_FILE" ]]; then
    # P2-3: never let a failing `cat` (unreadable file: foreign-owned state
    # dir, chmod 000, bad restore) reach the script-wide ERR trap as the
    # tail of an `&&` list -- that would silence this hook on every Stop,
    # permanently, with no bb call and no retry.
    PREV_BAND="$(cat "$BAND_FILE" 2>/dev/null)" || PREV_BAND=""
fi
[[ "$PREV_BAND" == "$band" ]] && exit 0

_persist_band() {
    [[ "$STATE_WRITABLE" == true ]] || return 0
    # Grouped so 2>/dev/null actually covers a failure to OPEN "$BAND_FILE"
    # for writing (e.g. a foreign-owned/unreadable band file left over from
    # a prior run): `cmd > "$f" 2>/dev/null` alone applies redirects
    # left-to-right, so a failed `> "$f"` open prints its "Permission
    # denied" straight to the real stderr before `2>/dev/null` ever takes
    # effect. Wrapping in a group applies both redirects to the group as a
    # unit first.
    { printf '%s' "$band" > "$BAND_FILE"; } 2>/dev/null || true
}

# Provider must be a bb-recognized backend name; model must look like a
# real model identifier (no spaces, no shell metacharacters). Anything else
# from the resolver -- including injection attempts (";", spaces) or an
# unknown provider -- is rejected before it ever becomes part of a "Run:"
# command (P3 allowlist hardening; a substring Opus denylist alone lets
# e.g. "claude-fable-5-1" straight through, and validates nothing about the
# provider).
_ip_valid_provider() {
    case "$1" in
        claude-code|codex) return 0 ;;
        *) return 1 ;;
    esac
}
_ip_valid_model() {
    [[ "$1" =~ ^[a-z0-9][a-z0-9._-]*$ ]]
}

# Locate an installed Clavain's scripts/coordinator-model.sh when the plain
# name isn't on PATH. Established pattern, not invented here:
#   1. installed_plugins.json's "clavain@<marketplace>" installPath -- the
#      same lookup Clavain's own hooks/release-canary-check.sh does against
#      that file (installPath existence + a parseable plugin.json).
#      "clavain@interagency-marketplace" (the canonical marketplace key) is
#      preferred when present; any other "clavain@*" key is used only if
#      that exact key is absent.
#   2. Failing that, the plugin-cache glob interline's scripts/statusline.sh
#      already uses to find Clavain's version
#      (~/.claude/plugins/cache/*/clavain/*), taking the most recently
#      modified match that isn't marked `.orphaned_at` and has a parseable
#      plugin.json.
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
            .plugins // {} | to_entries
            | (map(select(.key == "clavain@interagency-marketplace"))
               + map(select(.key | test("^clavain@"))))
            | .[0].value[0].installPath // empty
        ' "$installed_file" 2>/dev/null)" || root=""
        if [[ -n "$root" ]]; then
            # A usable install has a PARSEABLE plugin.json, not merely an
            # installPath that exists (a half-written or corrupted install
            # is not trusted just because the directory is there).
            jq -e . "$root/.claude-plugin/plugin.json" >/dev/null 2>&1 || root=""
        fi
    fi

    if [[ -z "$root" || ! -d "$root" ]]; then
        root=""
        local newest_mtime=-1 mtime
        shopt -s nullglob
        for candidate in "$cache_root"/*/clavain/*; do
            [[ -d "$candidate" ]] || continue
            [[ -e "$candidate/.orphaned_at" ]] && continue
            jq -e . "$candidate/.claude-plugin/plugin.json" >/dev/null 2>&1 || continue
            mtime="$(stat -c %Y "$candidate" 2>/dev/null || stat -f %m "$candidate" 2>/dev/null || echo -1)"
            [[ "$mtime" =~ ^-?[0-9]+$ ]] || mtime=-1
            if (( mtime > newest_mtime )); then
                newest_mtime="$mtime"
                root="$candidate"
            fi
        done
        shopt -u nullglob
    fi

    [[ -n "$root" && -f "$root/scripts/coordinator-model.sh" ]] || return 1
    printf '%s\n' "$root/scripts/coordinator-model.sh"
}

# Resolve the coordinator model by calling Clavain's scripts/coordinator-model.sh
# as an external command -- never reimplemented here. Always returns a usable
# "<provider> <model>" pair; never leaves the caller without one, and never
# an Opus-class model.
resolve_coordinator_model() {
    local cmd="" resolved="" provider model

    # P2-4: this call is OPTIONAL (a hardcoded Sonnet fallback always covers
    # it) -- past the time budget, skip straight to that fallback rather
    # than risk the search/invocation pushing this Stop past its hooks.json
    # timeout.
    if _ip_elapsed_over_budget; then
        printf '%s %s\n' "claude-code" "claude-sonnet-5"
        return 0
    fi

    cmd="${CLAVAIN_COORDINATOR_MODEL_CMD:-}"
    if [[ -z "$cmd" ]]; then
        cmd="coordinator-model.sh"
        if ! command -v "$cmd" >/dev/null 2>&1; then
            local found=""
            found="$(find_clavain_coordinator_model)" || found=""
            [[ -n "$found" ]] && cmd="$found"
        fi
    fi

    if command -v "$cmd" >/dev/null 2>&1; then
        # Hard bound: SIGKILL follows SIGTERM after 0.2s. Without timeout the
        # resolver is not run and the documented fallback pair is used.
        if command -v timeout >/dev/null 2>&1; then
            resolved="$(timeout -k 0.2 1 "$cmd" 2>/dev/null)" || resolved=""
        fi
    fi

    provider="${resolved%% *}"
    model="${resolved#* }"
    if [[ -z "$resolved" || "$provider" == "$resolved" || -z "$provider" || -z "$model" ]] \
        || ! _ip_valid_provider "$provider" || ! _ip_valid_model "$model"; then
        # coordinator-model.sh not on PATH, it failed/produced unusable
        # output, or its output didn't pass the provider/model allowlist
        # (P3 -- catches injection attempts and unknown providers, not just
        # Opus): fail soft to the exact fallback pair it documents for its
        # own error paths. This never blocks a directive on the resolver
        # being unavailable or untrustworthy.
        provider="claude-code"
        model="claude-sonnet-5"
    fi

    # Defense in depth: this role never runs Opus, regardless of what a
    # broken or misconfigured external resolver printed. coordinator-model.sh
    # already refuses Opus internally; this is a second, independent check
    # against forwarding one anyway. (The allowlist above does not catch
    # this alone: "claude-opus-5-5" matches the model charset.)
    case "${model,,}" in
        *opus*) provider="claude-code"; model="claude-sonnet-5" ;;
    esac

    printf '%s %s\n' "$provider" "$model"
}

# Strip a trailing dated-snapshot suffix (-YYYYMMDD) before comparing model
# strings (P3): a transcript that records a dated snapshot ID would
# otherwise never equal the resolver's undated alias, so every band would
# emit a spurious --replace even when the coordinator is already on the
# right model family.
_ip_strip_dated_suffix() {
    local m="$1"
    [[ "$m" =~ ^(.*)-[0-9]{8}$ ]] && m="${BASH_REMATCH[1]}"
    printf '%s' "$m"
}

# --- Who counts as a coordinator (bb consulted fresh, once per band) ---
# Every bb-lookup failure below exits WITHOUT calling _persist_band, so the
# band file never claims this Stop reached a determination it didn't.
command -v bb >/dev/null 2>&1 || exit 0
# Every external call must be hard-bounded: without `timeout` we cannot
# bound them, so stay silent. `-k 0.2` sends SIGKILL if SIGTERM is ignored.
command -v timeout >/dev/null 2>&1 || exit 0
TIMEOUT_CMD=(timeout -k 0.2 1)

IS_COORDINATOR="false"
ROTATION_ENABLED="false"
ROTATE_AT=""

STATUS_JSON="$("${TIMEOUT_CMD[@]}" bb handoff coordinator status --self --json 2>/dev/null)" || exit 0
[[ -n "$STATUS_JSON" ]] || exit 0
MARKED="$(jq -r 'if .marking == null then "false" else "true" end' <<<"$STATUS_JSON" 2>/dev/null)" || exit 0

if [[ "$MARKED" == "true" ]]; then
    IS_COORDINATOR="true"
    ROTATION_ENABLED="$(jq -r '.rotationEnabled // false' <<<"$STATUS_JSON" 2>/dev/null)" || true
    ROTATE_AT="$(jq -r '.marking.rotateAt // empty' <<<"$STATUS_JSON" 2>/dev/null)" || true
else
    # Overall deadline: skip the second lookup if the first ate the budget.
    _ip_elapsed_over_budget && exit 0
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
                if _ip_elapsed_over_budget; then
                    # P2-4: this lookup is OPTIONAL (see the fallback
                    # below) -- past the time budget, treat it the same as
                    # a failed/timed-out call rather than risk pushing this
                    # Stop past its hooks.json timeout.
                    WINDOW=""
                else
                    # `|| true`: a nonzero exit here (bb failure/timeout) falls
                    # through to "window unknown" below, never toward silence.
                    CONTEXT_JSON="$("${TIMEOUT_CMD[@]}" bb thread context "$BB_THREAD_ID" --json 2>/dev/null)" || true
                    WINDOW="$(jq -r '.usage.modelContextWindow // empty' <<<"$CONTEXT_JSON" 2>/dev/null)" || true
                    [[ "$WINDOW" =~ ^[0-9]+$ ]] || WINDOW=""
                fi
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
    [[ "$(_ip_strip_dated_suffix "$MODEL")" == "$(_ip_strip_dated_suffix "$RESOLVED_MODEL")" ]] && MODEL_OK="true"

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
            # Always follow `enable` with the ready `--replace` command so
            # the directive is complete in one pass.
            NEED_ENABLE="true"
            NEED_REPLACE="true"
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

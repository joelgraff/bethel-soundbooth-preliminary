#!/bin/bash
# presonus-usb-watch.sh — Watch the PreSonus 32SX for FOH-silencing failures
# that don't show up as a simple "service crashed" — restart the bridge to
# force recovery, same debounce/cap pattern as the other *-watch.sh scripts
# in this repo (camera-management-watch.sh, ffmpeg-capture-watch.sh).
#
# Built 2026-09-04 after a night of recurring FOH silence with every
# individual signal looking healthy in isolation. Three real failure modes
# were found, none of which any single existing check caught on its own:
#
#   1. `amixer -c N cget` (StudioLive Internal Clock Validity) can itself
#      be stale — it read "on" while the kernel log showed live, repeated
#      usb_set_interface/clock-source failures on every retry (20:38).
#   2. The kernel log can be completely clean, `amixer` can say "on", and
#      the board's physical meter can still be dead (21:00) — the
#      USB link and ALSA driver state both look fine while the aplay
#      process had gone stale relative to a since-reset connection.
#   3. The deepest one: ALSA's hw_ptr (actual hardware playback position)
#      can freeze — state stays RUNNING, no kernel error, `amixer` says
#      "on" — while the device has silently stopped consuming audio
#      entirely (21:03). This script's hw_ptr check is the only one of
#      the three that catches this specific mode.
#
# None of these are reliably distinguishable from a single check — this
# script ORs all three together, and DOES NOT treat any one of them alone
# as sufficient proof of health.
#
# Env (optional, conf or service Environment=):
#   PRESONUS_WATCH_POLL_SEC        poll interval seconds (default 15)
#   PRESONUS_WATCH_MIN_GAP_SEC     debounce between restarts (default 60)
#   PRESONUS_WATCH_MAX_PER_HOUR    cap restarts (default 10 — this board is
#                                  known to need frequent recovery some
#                                  nights; the cap is a backstop, not a
#                                  expected-frequency target)
#   PRESONUS_WATCH_DISABLE=1       no-op loop (for testing)
#
# systemctl --user status presonus-usb-watch.service

set -uo pipefail

POLL="${PRESONUS_WATCH_POLL_SEC:-15}"
MIN_GAP="${PRESONUS_WATCH_MIN_GAP_SEC:-60}"
MAX_HOUR="${PRESONUS_WATCH_MAX_PER_HOUR:-10}"
# Run the far-side loopback check every Nth poll (default every 20 polls =
# ~5 min). Deliberately not every poll: each check opens a second stream on
# a device that has proven fragile, so it's kept infrequent.
LOOPBACK_EVERY="${PRESONUS_WATCH_LOOPBACK_EVERY:-20}"
LOOPBACK_CHECK="${PRESONUS_WATCH_LOOPBACK_CHECK:-$HOME/bin/presonus-loopback-check.py}"
STATE_DIR="${XDG_RUNTIME_DIR:-/tmp}/soundbooth-presonus-usb-watch"
mkdir -p "$STATE_DIR"
RESTART_LOG="${STATE_DIR}/restarts.log"
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/soundbooth-watch-lib.sh"

log() { echo "[presonus-usb-watch $(date +%H:%M:%S)] $*"; }

card_num() {
    # Portable form — the 3-arg match(s, r, array) capture syntax used
    # previously is a gawk extension; this system's /usr/bin/awk is mawk,
    # which doesn't support it and threw "syntax error at or near ,"
    # every time a match was attempted (found live 2026-09-04 21:17,
    # right after the post-reboot re-test — mawk vs gawk wasn't checked
    # before deploying the first version).
    aplay -l 2>/dev/null | grep -oP 'card \K[0-9]+(?=.*S32SX)' | head -1
}

do_restart() {
    local reason="$1" now n
    if [[ "${PRESONUS_WATCH_DISABLE:-0}" == "1" ]]; then
        log "DISABLE set — would restart for: $reason"
        return
    fi
    now=$(date +%s)
    if [[ -n "${LAST_RESTART:-}" ]] && (( now - LAST_RESTART < MIN_GAP )); then
        log "debounced (${MIN_GAP}s) — $reason"
        return
    fi
    n=$(count_restarts_last_hour "$RESTART_LOG")
    if (( n >= MAX_HOUR )); then
        log "MAX restarts/hour (${MAX_HOUR}) reached — NOT restarting ($reason)." \
            "This almost certainly needs a physical power-cycle of the board, not another software restart."
        return
    fi
    log "restarting presonus-foh-bridge (${reason}) [hour count $((n + 1))/${MAX_HOUR}]"
    if systemctl --user restart presonus-foh-bridge.service; then
        LAST_RESTART=$now
        record_restart "$RESTART_LOG"
    else
        log "ERROR: systemctl restart presonus-foh-bridge failed"
    fi
}

# --- USB reset escalation -------------------------------------------------
# Restarting the bridge only helps when the host side lost its stream. It is
# useless against the wedged-but-attached failure found 2026-09-05, where the
# device stays enumerated and answers no control transfers: 1,375 bridge
# restarts across that night changed nothing, because there was nothing to
# reopen. A USB port reset is the only remedy short of physically
# power-cycling the board, so once restarts have demonstrably not worked,
# escalate to one. Rate-limited separately and much more tightly than
# restarts — a reset is disruptive, and hammering a marginal link with them
# is exactly the pattern that made things worse before.
RESET_HELPER_CALLER="${PRESONUS_WATCH_RECOVER:-$HOME/bin/presonus-recover.sh}"
RESET_AFTER_BAD_POLLS="${PRESONUS_WATCH_RESET_AFTER:-6}"
RESET_MIN_GAP="${PRESONUS_WATCH_RESET_MIN_GAP_SEC:-300}"
RESET_MAX_HOUR="${PRESONUS_WATCH_MAX_RESETS_PER_HOUR:-3}"
RESET_LOG="${STATE_DIR}/resets.log"
RESET_UNAVAILABLE_LOGGED=false

# Both halves must be present: the unprivileged orchestrator AND the sudo
# grant for the privileged helper. Checking only the former would report the
# escalation "armed" while every attempt refused at the sudo step.
# NOT `sudo -n -l <cmd>` — that answers "is the user authorized", not "can
# they run it without a password". soundbooth is in the sudo group and so
# has a blanket (ALL : ALL) ALL entry, making that check return true for any
# command. It reported the escalation armed on 2026-09-05 while no NOPASSWD
# fragment existed. Exercise the grant instead, via the read-only --probe.
reset_available() {
    [[ -x "$RESET_HELPER_CALLER" ]] || return 1
    local out
    out="$(sudo -n /usr/local/sbin/presonus-usb-reset --probe 2>&1)"
    grep -qi "password is required" <<< "$out" && return 1
    return 0
}

do_usb_reset() {
    local reason="$1" now n
    if [[ "${PRESONUS_WATCH_DISABLE:-0}" == "1" ]]; then
        log "DISABLE set — would attempt USB reset for: $reason"
        return
    fi
    if ! reset_available; then
        if ! $RESET_UNAVAILABLE_LOGGED; then
            log "USB reset escalation unavailable (orchestrator or sudo grant missing)." \
                "Install with: sudo audio-routing/scripts/install-usb-reset-helper.sh"
            RESET_UNAVAILABLE_LOGGED=true
        fi
        return
    fi
    now=$(date +%s)
    if [[ -n "${LAST_RESET:-}" ]] && (( now - LAST_RESET < RESET_MIN_GAP )); then
        return   # silent: this is checked every poll, don't spam the journal
    fi
    n=$(count_restarts_last_hour "$RESET_LOG")
    if (( n >= RESET_MAX_HOUR )); then
        log "MAX USB resets/hour (${RESET_MAX_HOUR}) reached — NOT resetting ($reason)." \
            "The board needs a physical power-cycle."
        LAST_RESET=$now   # re-arm the gap so this doesn't log every poll
        return
    fi
    log "ESCALATING to USB reset (${reason}) [hour count $((n + 1))/${RESET_MAX_HOUR}]"
    LAST_RESET=$now
    local out rc
    out="$("$RESET_HELPER_CALLER" --quiet 2>&1)"; rc=$?
    while IFS= read -r line; do [[ -n "$line" ]] && log "  $line"; done <<< "$out"
    case $rc in
        0) log "USB reset reported success — will re-verify on the next poll" ;;
        2) log "USB reset: board not attached (powered off/unplugged)" ;;
        3) log "USB reset refused (recording in progress, or grant not installed)" ;;
        *) log "USB reset did not recover the device — physical power-cycle required" ;;
    esac
}

log "watching PreSonus 32SX (amixer + kernel log + hw_ptr) — poll ${POLL}s, min gap ${MIN_GAP}s, max ${MAX_HOUR}/h"
if reset_available; then
    if (( RESET_AFTER_BAD_POLLS >= 100000 )); then
        # Deliberately-disabled sentinel (see the no-reset-escalation drop-in).
        # Reporting this as "ARMED after 999999 polls" invites someone to
        # believe recovery is covered when it is switched off.
        log "USB reset escalation DISABLED by configuration (RESET_AFTER=${RESET_AFTER_BAD_POLLS}) — bridge restarts only"
    else
        log "USB reset escalation ARMED: after ${RESET_AFTER_BAD_POLLS} consecutive bad polls, max ${RESET_MAX_HOUR}/h"
    fi
else
    log "USB reset escalation NOT available (orchestrator or sudo grant missing) — bridge restarts only." \
        "Install with: sudo audio-routing/scripts/install-usb-reset-helper.sh"
fi

LAST_STATE="unknown"
POLL_COUNT=0
BAD_STREAK=0
while true; do
    sleep "$POLL"

    CARD=$(card_num)
    if [[ -z "$CARD" ]]; then
        # Board not enumerated at all — genuinely down, not just degraded.
        STATE="bad"
        REASON="card not present"
    else
        AMIXER_OK=false
        amixer -c "$CARD" cget numid=1 2>/dev/null | grep -q "values=on" && AMIXER_OK=true

        KERNEL_BAD=false
        if journalctl -k --since "-${POLL}sec" --no-pager 2>/dev/null | \
            grep -qE "usb_set_interface failed|clock source.*is not valid|cannot get freq \(v2/v3\)|device descriptor read/64, error|USB disconnect"; then
            KERNEL_BAD=true
        fi

        # hw_ptr is a ring-buffer position (wraps every ~20ms during
        # normal playback), so it's only meaningful sampled twice within
        # one short window, not across the full poll interval.
        HWPTR_STUCK=false
        PCM_STATUS="/proc/asound/card${CARD}/pcm0p/sub0/status"
        if [[ -r "$PCM_STATUS" ]]; then
            READ1=$(cat "$PCM_STATUS" 2>/dev/null)
            STATE1=$(echo "$READ1" | awk -F': *' '/^state/{print $2}')
            PTR1=$(echo "$READ1" | awk -F': *' '/^hw_ptr/{print $2}')
            sleep 1.5
            READ2=$(cat "$PCM_STATUS" 2>/dev/null)
            STATE2=$(echo "$READ2" | awk -F': *' '/^state/{print $2}')
            PTR2=$(echo "$READ2" | awk -F': *' '/^hw_ptr/{print $2}')
            if [[ "$STATE1" == "RUNNING" && "$STATE2" == "RUNNING" && -n "$PTR1" && "$PTR1" == "$PTR2" ]]; then
                HWPTR_STUCK=true
            fi
        fi

        # Far-side loopback check — the only signal that observes whether
        # the BOARD is actually processing our audio, rather than just
        # whether the host thinks it sent it. Every check opens a second
        # stream on the device, so it runs infrequently (see
        # LOOPBACK_EVERY). Exit 1 = confirmed silent failure. Exit 2 =
        # nothing playing, can't judge. Exit 3 = couldn't capture — benign
        # only if something actually holds the capture device (operator
        # recording); otherwise it's a failure in its own right (see below).
        LOOPBACK_BAD=false
        POLL_COUNT=$((POLL_COUNT + 1))
        if (( POLL_COUNT % LOOPBACK_EVERY == 0 )) && [[ -x "$LOOPBACK_CHECK" ]]; then
            LB_OUT=$("$LOOPBACK_CHECK" 2>&1)
            LB_RC=$?
            case "$LB_RC" in
                0) log "loopback OK — $LB_OUT" ;;
                1) LOOPBACK_BAD=true; log "loopback check FAILED: $LB_OUT" ;;
                2) log "loopback skipped — nothing playing" ;;
                *)
                    # rc=3 means the capture itself wouldn't open. Originally
                    # treated as "unknown, don't act" on the theory that an
                    # operator recording legitimately holds the device. That
                    # was wrong and cost ~48 minutes of blindness on
                    # 2026-09-05 00:51-01:39: nothing held the device, every
                    # failed attempt was itself generating a kernel -71, and
                    # the watchdog logged it as benign the whole time.
                    # Correct discriminator: if nothing actually holds the
                    # capture device, a capture failure IS a device failure.
                    if fuser /dev/snd/pcmC${CARD}D0c >/dev/null 2>&1; then
                        log "loopback check skipped — capture device busy (recording in progress?)"
                    else
                        LOOPBACK_BAD=true
                        log "loopback check FAILED to open capture and nothing holds the device (rc=$LB_RC): $LB_OUT"
                    fi
                    ;;
            esac
        fi

        if $AMIXER_OK && ! $KERNEL_BAD && ! $HWPTR_STUCK && ! $LOOPBACK_BAD; then
            STATE="ok"
        else
            STATE="bad"
            REASON="amixer_ok=$AMIXER_OK kernel_bad=$KERNEL_BAD hwptr_stuck=$HWPTR_STUCK loopback_bad=$LOOPBACK_BAD"
        fi
    fi

    if [[ "$STATE" == "bad" ]]; then
        BAD_STREAK=$((BAD_STREAK + 1))
    else
        BAD_STREAK=0
    fi

    if [[ "$STATE" == "bad" && "$LAST_STATE" == "ok" ]]; then
        log "ALERT: PreSonus 32SX unhealthy ($REASON)"
        do_restart "$REASON"
    elif [[ "$STATE" == "bad" ]]; then
        # Still bad on a later poll — try another restart if debounce allows
        # (covers the case where a software restart alone won't fix it, but
        # is still worth attempting periodically in case it does).
        do_restart "$REASON (still bad)"
        # Restarts have now had several attempts and the device is still
        # bad, which is the signature of a wedge a restart cannot fix.
        if (( BAD_STREAK >= RESET_AFTER_BAD_POLLS )); then
            do_usb_reset "$REASON (bad for ${BAD_STREAK} consecutive polls)"
        fi
    fi
    if [[ "$STATE" == "ok" && "$LAST_STATE" == "bad" ]]; then
        log "RECOVERED"
    fi
    LAST_STATE="$STATE"
done

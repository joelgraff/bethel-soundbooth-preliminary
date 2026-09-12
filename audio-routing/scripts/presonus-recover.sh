#!/bin/bash
# presonus-recover.sh — unprivileged orchestrator around the privileged USB
# reset helper. This is the thing you (or presonus-usb-watch.sh) actually
# call; it owns everything that does NOT need root.
#
#   stop the bridge -> sudo presonus-usb-reset -> wait for the card ->
#   start the bridge -> verify with the far-side loopback check
#
# Stopping the bridge first matters. presonus-foh-bridge.service holds the
# playback device open via aplay; resetting the USB device out from under a
# live stream is how you turn a recoverable wedge into a worse one. The
# bridge is a --user unit, so this half stays unprivileged and the root
# helper never has to reach into another user's systemd session.
#
# Usage:
#   presonus-recover.sh              full recovery
#   presonus-recover.sh --dry-run    print the plan, change nothing
#   presonus-recover.sh --force      proceed even if a recording is running
#   presonus-recover.sh --quiet      only print the final verdict
#
# Exit codes:
#   0  recovered and verified (or --dry-run completed)
#   1  reset ran but the device is still not working — needs a power-cycle
#   2  board not attached at all (powered off / unplugged)
#   3  refused to run (recording in progress, another instance, unsafe setup)

set -uo pipefail

HELPER="/usr/local/sbin/presonus-usb-reset"
LOOPBACK_CHECK="${PRESONUS_LOOPBACK_CHECK:-$HOME/bin/presonus-loopback-check.py}"
BRIDGE="presonus-foh-bridge.service"
STATE_DIR="${XDG_RUNTIME_DIR:-/tmp}/soundbooth-presonus-usb-watch"
mkdir -p "$STATE_DIR"
RESET_LOG="${STATE_DIR}/resets.log"

DRY_RUN=0; FORCE=0; QUIET=0
for a in "$@"; do
    case "$a" in
        --dry-run) DRY_RUN=1 ;;
        --force)   FORCE=1 ;;
        --quiet)   QUIET=1 ;;
        *) echo "presonus-recover.sh: unknown option '$a'" >&2; exit 3 ;;
    esac
done

log() { (( QUIET )) || echo "[presonus-recover $(date +%H:%M:%S)] $*"; }
verdict() { echo "[presonus-recover $(date +%H:%M:%S)] $*"; }

# --- singleton: two concurrent resets of the same device is asking for it --
exec 9>"${STATE_DIR}/recover.lock"
if ! flock -n 9; then
    verdict "another recovery is already running — exiting"
    exit 3
fi

card_num() {
    aplay -l 2>/dev/null | grep -oP 'card \K[0-9]+(?=.*S32SX)' | head -1
}

# --- safety: never yank the device out from under a live recording --------
CARD="$(card_num)"
if [[ -n "$CARD" ]] && fuser /dev/snd/pcmC${CARD}D0c >/dev/null 2>&1; then
    if (( FORCE )); then
        log "WARNING: a recording is holding the capture device; --force given, continuing anyway"
    else
        verdict "REFUSING: a recording is in progress (something holds /dev/snd/pcmC${CARD}D0c)."
        verdict "Stop the recording first, or re-run with --force to sacrifice it."
        exit 3
    fi
fi

# --- safety: the sudo grant is only safe while the helper is root-owned ---
if [[ ! -x "$HELPER" ]]; then
    verdict "REFUSING: ${HELPER} is not installed."
    verdict "Install it: sudo audio-routing/scripts/install-usb-reset-helper.sh"
    exit 3
fi
owner="$(stat -c '%U' "$HELPER" 2>/dev/null)"
mode="$(stat -c '%a' "$HELPER" 2>/dev/null)"
if [[ "$owner" != "root" ]]; then
    verdict "REFUSING: ${HELPER} is owned by '${owner}', not root — the sudo grant would be a root escalation."
    exit 3
fi
# Octal arithmetic rather than a pattern match: 0022 is the group+other write
# bits, and this stays correct for 4-digit modes like 2755 that a regex on
# digit positions would misread.
if (( 8#${mode} & 0022 )); then
    verdict "REFUSING: ${HELPER} is group- or world-writable (mode ${mode}) — unsafe with a NOPASSWD grant."
    exit 3
fi

# Check the grant by actually exercising it, not with `sudo -n -l "$HELPER"`.
#
# `sudo -l CMD` answers "is this user AUTHORIZED to run CMD", not "can they
# run it WITHOUT a password". soundbooth is in the sudo group and therefore
# has a blanket `(ALL : ALL) ALL` entry, so that check returns success for
# literally any command and is worthless here. It passed on 2026-09-05 while
# the NOPASSWD fragment was not installed at all, and the run went on to fail
# at the real sudo call.
#
# --probe is the safe way to exercise it: read-only, takes no action.
PROBE_OUT="$(sudo -n "$HELPER" --probe 2>&1)"; PROBE_RC=$?
if grep -qi "password is required" <<< "$PROBE_OUT"; then
    verdict "REFUSING: no passwordless sudo grant for ${HELPER}."
    verdict "Install it: sudo audio-routing/scripts/install-usb-reset-helper.sh"
    exit 3
fi
if (( PROBE_RC != 0 )); then
    verdict "REFUSING: could not run ${HELPER} --probe (rc=${PROBE_RC}): ${PROBE_OUT}"
    exit 3
fi

if (( DRY_RUN )); then
    log "DRY RUN — would do:"
    log "  1. systemctl --user stop ${BRIDGE}"
    log "  2. sudo -n ${HELPER}"
    log "  3. wait for the S32SX ALSA card to reappear (up to 30s)"
    log "  4. systemctl --user start ${BRIDGE}"
    log "  5. verify with ${LOOPBACK_CHECK}"
    log "current state: card=${CARD:-<absent>} bridge=$(systemctl --user is-active "$BRIDGE" 2>/dev/null)"
    log "probing the device (no action taken):"
    sudo -n "$HELPER" --probe 2>&1 | sed 's/^/    /'
    exit 0
fi

# Single accounting point for reset rate-limiting: presonus-usb-watch.sh
# reads this same file to enforce its per-hour cap, so a manual run counts
# against the automatic budget too — which is what you want, since the
# device does not care who initiated the reset.
date +%s >> "$RESET_LOG"
if [[ -f "$RESET_LOG" ]] && [[ "$(wc -l < "$RESET_LOG")" -gt 200 ]]; then
    tail -n 100 "$RESET_LOG" > "${RESET_LOG}.tmp" && mv "${RESET_LOG}.tmp" "$RESET_LOG"
fi

log "stopping ${BRIDGE}"
systemctl --user stop "$BRIDGE" 2>/dev/null
sleep 1

log "invoking privileged reset"
RESET_OUT="$(sudo -n "$HELPER" 2>&1)"; RESET_RC=$?
echo "$RESET_OUT" | sed 's/^/    /'

# sudo being denied is not a statement about the device. Reporting it as
# "device still unresponsive — needs a physical power-cycle" sends someone
# to the building over a permissions problem; that exact misreport happened
# on 2026-09-05 07:47 before the grant was installed.
if grep -qi "password is required\|sudo: a password" <<< "$RESET_OUT"; then
    verdict "FAILED: sudo denied the reset helper — the NOPASSWD grant is missing or broken."
    verdict "This says NOTHING about the board. Install: sudo audio-routing/scripts/install-usb-reset-helper.sh"
    systemctl --user start "$BRIDGE" 2>/dev/null
    exit 3
fi

if [[ $RESET_RC -eq 2 ]]; then
    verdict "board is not attached at all — it is powered off or unplugged. Nothing to reset."
    systemctl --user start "$BRIDGE" 2>/dev/null
    exit 2
fi

log "waiting for the ALSA card to reappear"
deadline=$((SECONDS + 30))
while (( SECONDS < deadline )); do
    CARD="$(card_num)"
    [[ -n "$CARD" ]] && break
    sleep 1
done

if [[ -z "$CARD" ]]; then
    verdict "FAILED: the S32SX ALSA card never came back after the reset."
    verdict "This needs a physical power-cycle of the board."
    systemctl --user start "$BRIDGE" 2>/dev/null
    exit 1
fi
log "card ${CARD} present"

log "starting ${BRIDGE}"
systemctl --user start "$BRIDGE" 2>/dev/null
sleep 4

if [[ $RESET_RC -ne 0 ]]; then
    verdict "FAILED: reset helper reported the device still unresponsive (rc=${RESET_RC})."
    verdict "This needs a physical power-cycle of the board."
    exit 1
fi

# --- verify on the far side ----------------------------------------------
# The host-side signals have all been proven to read healthy during a real
# failure, so a bridge that is merely 'active' is not evidence of anything.
if [[ -x "$LOOPBACK_CHECK" ]]; then
    log "verifying with the far-side loopback check"
    LB_OUT="$("$LOOPBACK_CHECK" --verbose 2>&1)"; LB_RC=$?
    echo "$LB_OUT" | sed 's/^/    /'
    case "$LB_RC" in
        0) verdict "RECOVERED — loopback confirmed. FOH audio is verified working." ; exit 0 ;;
        2) verdict "reset completed and the device is responding, but nothing is playing so the"
           verdict "loopback check could not confirm audio end-to-end. Start Spotify and re-verify."
           exit 0 ;;
        *) verdict "FAILED: device responds to control transfers but audio does not reach the board."
           verdict "This needs a physical power-cycle."
           exit 1 ;;
    esac
else
    verdict "reset completed; loopback check not installed at ${LOOPBACK_CHECK}, so this is UNVERIFIED."
    exit 0
fi

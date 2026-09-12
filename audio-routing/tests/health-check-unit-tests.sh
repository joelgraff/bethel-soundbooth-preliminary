#!/bin/bash
# Unit tests for individual soundbooth-health.sh check_* functions, using
# fake systemctl/lsusb/ss stubs (PATH-shimmed) instead of live hardware.
#
# Every check in soundbooth-health.sh was previously only ever exercised
# against real system state — a parsing regression (e.g. a systemctl/lsusb
# output format change, or a logic bug in a new check) would only be caught
# by silently mis-reporting on the live booth. This covers a slice of the
# higher-risk / recently-changed checks with controllable inputs instead:
#   - check_usb              (lsusb parsing)
#   - check_services          (EXPECTED_SERVICES active/inactive/missing)
#   - check_no_vlc_service    (multi-branch active/enabled/leftover/absent)
#   - check_camera_management (2026-08-23: "active" service with a silently
#                               dead RTSP pipeline — the exact failure mode
#                               that motivated this check's existence)
#
# How: sources soundbooth-health.sh with SOUNDBOOTH_HEALTH_SELFTEST=1, which
# skips the script's own top-level run-and-exit (see bottom of that file),
# leaving check_*/log_result/RESULTS callable directly in this shell.
#
# Usage: ./health-check-unit-tests.sh
# Exit: 0 = all assertions passed, 1 = one or more failed.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HEALTH="${HOME}/bin/soundbooth-health.sh"
[[ -f "$HEALTH" ]] || HEALTH="${HERE}/../scripts/soundbooth-health.sh"
if [[ ! -f "$HEALTH" ]]; then
    echo "FAIL: soundbooth-health.sh not found" >&2
    exit 1
fi

FAKEBIN="$(mktemp -d)"
trap 'rm -rf "$FAKEBIN"' EXIT
export PATH="${FAKEBIN}:${PATH}"

# --- fake systemctl ----------------------------------------------------
# Controlled via env:
#   FAKE_SYSTEMCTL_KNOWN_UNITS   space list — `cat UNIT` succeeds only for these
#   FAKE_SYSTEMCTL_ACTIVE_UNITS  space list — `is-active UNIT` prints active
#   FAKE_SYSTEMCTL_ENABLED_UNITS space list — `is-enabled UNIT` succeeds
#   FAKE_SYSTEMCTL_ACTIVE_ENTER_TS / FAKE_SYSTEMCTL_MAIN_PID — `show -p ...`
cat > "${FAKEBIN}/systemctl" <<'STUB'
#!/bin/bash
sub="" unit="" prop="" want_prop=0 quiet=0
for a in "$@"; do
    case "$a" in
        --user|--value) ;;
        --quiet) quiet=1 ;;
        cat|is-active|is-enabled|show|restart|start|stop|try-restart)
            [[ -z "$sub" ]] && sub="$a" ;;
        -p) want_prop=1 ;;
        *)
            if [[ "$want_prop" == "1" ]]; then prop="$a"; want_prop=0
            elif [[ -z "$unit" && "$a" != -* ]]; then unit="$a"
            fi
            ;;
    esac
done
known=" ${FAKE_SYSTEMCTL_KNOWN_UNITS:-} "
active=" ${FAKE_SYSTEMCTL_ACTIVE_UNITS:-} "
enabled=" ${FAKE_SYSTEMCTL_ENABLED_UNITS:-} "
case "$sub" in
    cat)
        [[ "$known" == *" $unit "* ]] && { echo "# fake $unit"; exit 0; }
        exit 1 ;;
    is-active)
        if [[ "$active" == *" $unit "* ]]; then [[ $quiet == 1 ]] || echo active; exit 0
        else [[ $quiet == 1 ]] || echo inactive; exit 3; fi ;;
    is-enabled)
        if [[ "$enabled" == *" $unit "* ]]; then [[ $quiet == 1 ]] || echo enabled; exit 0
        else [[ $quiet == 1 ]] || echo disabled; exit 1; fi ;;
    show)
        case "$prop" in
            ActiveEnterTimestamp) echo "${FAKE_SYSTEMCTL_ACTIVE_ENTER_TS:-n/a}" ;;
            MainPID) echo "${FAKE_SYSTEMCTL_MAIN_PID:-0}" ;;
            *) echo "" ;;
        esac
        exit 0 ;;
    restart|start|stop|try-restart) exit 0 ;;
    *) exit 1 ;;
esac
STUB
chmod +x "${FAKEBIN}/systemctl"

# --- fake lsusb ----------------------------------------------------------
cat > "${FAKEBIN}/lsusb" <<'STUB'
#!/bin/bash
echo "${FAKE_LSUSB_OUTPUT:-}"
STUB
chmod +x "${FAKEBIN}/lsusb"

# --- fake ss ---------------------------------------------------------------
cat > "${FAKEBIN}/ss" <<'STUB'
#!/bin/bash
if [[ "${FAKE_SS_PORT_BOUND:-0}" == "1" ]]; then
    echo "LISTEN 0      511          *:${FAKE_SS_PORT:-9999}          *:*"
fi
STUB
chmod +x "${FAKEBIN}/ss"

# --- load check_* functions without auto-running ----------------------------
export SOUNDBOOTH_HEALTH_SELFTEST=1
# shellcheck disable=SC1090
source "$HEALTH"

TESTS=0
FAILURES=0

reset_state() {
    PASS=0; WARN=0; FAIL=0
    RESULTS=()
    unset FAKE_SYSTEMCTL_KNOWN_UNITS FAKE_SYSTEMCTL_ACTIVE_UNITS FAKE_SYSTEMCTL_ENABLED_UNITS
    unset FAKE_SYSTEMCTL_ACTIVE_ENTER_TS FAKE_SYSTEMCTL_MAIN_PID
    unset FAKE_LSUSB_OUTPUT FAKE_SS_PORT_BOUND FAKE_SS_PORT
}

# assert_result LEVEL SECTION SUBSTRING — true if a matching RESULTS entry exists
assert_result() {
    local level="$1" section="$2" substr="$3" r
    for r in "${RESULTS[@]}"; do
        [[ "$r" == "${level}|${section}|"*"${substr}"* ]] && return 0
    done
    return 1
}

no_results() { [[ ${#RESULTS[@]} -eq 0 ]]; }
no_fail()    { [[ "$FAIL" -eq 0 ]]; }

check() {
    local desc="$1"; shift
    TESTS=$((TESTS + 1))
    if "$@"; then
        echo "  ok   - $desc"
    else
        echo "  FAIL - $desc"
        FAILURES=$((FAILURES + 1))
    fi
}

echo "=== check_usb ==="
reset_state
export FAKE_LSUSB_OUTPUT=$'Bus 003 Device 004: ID 194f:0809 PreSonus StudioLive 32SX\nBus 003 Device 005: ID 1edb:beef Blackmagic Design ATEM'
check_usb
check "PreSonus present -> PASS" assert_result PASS usb "PreSonus"
check "ATEM present -> PASS"     assert_result PASS usb "ATEM"

reset_state
export FAKE_LSUSB_OUTPUT=""
check_usb
check "PreSonus absent -> FAIL"  assert_result FAIL usb "PreSonus"
check "ATEM absent -> FAIL"      assert_result FAIL usb "ATEM"

echo "=== check_services (EXPECTED_SERVICES) ==="
reset_state
export FAKE_SYSTEMCTL_KNOWN_UNITS="${EXPECTED_SERVICES[*]}"
export FAKE_SYSTEMCTL_ACTIVE_UNITS="${EXPECTED_SERVICES[*]}"
check_services
check "all expected active -> no FAIL" no_fail

reset_state
export FAKE_SYSTEMCTL_KNOWN_UNITS="${EXPECTED_SERVICES[*]}"
export FAKE_SYSTEMCTL_ACTIVE_UNITS="ffmpeg-capture.service"   # only one of several active
check_services
check "inactive expected service -> FAIL" assert_result FAIL service "ffmpeg-display.service"

reset_state
export FAKE_SYSTEMCTL_KNOWN_UNITS=""
export FAKE_SYSTEMCTL_ACTIVE_UNITS=""
check_services
check "missing unit file -> FAIL" assert_result FAIL service "unit file not found"

echo "=== check_no_vlc_service ==="
reset_state
export FAKE_SYSTEMCTL_KNOWN_UNITS=""
check_no_vlc_service
check "no VLC units -> PASS" assert_result PASS service "No VLC user services"

reset_state
export FAKE_SYSTEMCTL_KNOWN_UNITS="vlc.service"
export FAKE_SYSTEMCTL_ACTIVE_UNITS="vlc.service"
check_no_vlc_service
check "vlc.service active -> FAIL steals" assert_result FAIL service "steals"

reset_state
export FAKE_SYSTEMCTL_KNOWN_UNITS="vlc.service"
export FAKE_SYSTEMCTL_ENABLED_UNITS="vlc.service"
check_no_vlc_service
check "vlc.service enabled but inactive -> WARN still enabled" assert_result WARN service "still enabled"

reset_state
export FAKE_SYSTEMCTL_KNOWN_UNITS="vlc.service"
check_no_vlc_service
check "vlc.service present/inactive/disabled -> WARN leftover" assert_result WARN service "leftover"

echo "=== check_camera_management ==="
reset_state
export FAKE_SYSTEMCTL_KNOWN_UNITS=""
check_camera_management
check "unit not installed -> no result logged (optional check)" no_results

reset_state
export FAKE_SYSTEMCTL_KNOWN_UNITS="camera-management.service"
check_camera_management
check "unit installed but inactive -> WARN unavailable" assert_result WARN camera-mgmt "unavailable"

reset_state
export FAKE_SYSTEMCTL_KNOWN_UNITS="camera-management.service"
export FAKE_SYSTEMCTL_ACTIVE_UNITS="camera-management.service"
export FAKE_SS_PORT_BOUND=0
check_camera_management
check "active, :9999 NOT bound -> PASS active"        assert_result PASS camera-mgmt "active"
check "active, :9999 NOT bound -> WARN not listening" assert_result WARN camera-mgmt "not listening"

reset_state
export FAKE_SYSTEMCTL_KNOWN_UNITS="camera-management.service"
export FAKE_SYSTEMCTL_ACTIVE_UNITS="camera-management.service"
export FAKE_SS_PORT_BOUND=1
export FAKE_SS_PORT=9999
check_camera_management
check "active, :9999 bound -> PASS bound" assert_result PASS camera-mgmt "bound"

echo
echo "=== ${TESTS} checks, ${FAILURES} failed ==="
[[ "$FAILURES" -eq 0 ]]

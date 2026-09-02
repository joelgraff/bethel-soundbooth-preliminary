#!/bin/bash
# soundbooth-health.sh — Diagnostics for the church soundbooth PC.
#
# Checks against SYSTEM-STATE.md policies:
#   - Software audio → Mixer / Presonus (default sink preference)
#   - Program: FFmpeg SRT + ffplay on DP-4 / HDMI TV
#   - ATEM capture device + USB
#   - ATEM network control (ping ATEM_NETWORK_IP, default 192.168.2.252)
#   - Camera network (ping CAMERA_NETWORK_IP, default 192.168.1.202)
#   - Camera management (CMP): camera-management.service active + RTSP-MPEG
#     websocket actually bound on :9999 (service "active" alone does not
#     guarantee the transcode pipeline is up — see STATUS.md 2026-08-16)
#   - Program livestream audio path (ALSA capture + AAC in pipeline + journal xruns)
#   - FOH graph: Mixer monitor → Presonus AUX0/1 (not only app → Mixer)
#   - VLC must not run as a systemd service (manual media player only)
#   - Key user services
#   - Session autostart desktops (Spotify/FreeShow/browser/dashboard) + browser on DP-1
#
# Usage:
#   soundbooth-health.sh           # human report; exit 0=ok, 1=warn, 2=fail
#   soundbooth-health.sh --quiet   # summary line + exit code only
#   soundbooth-health.sh --json    # machine-readable (one JSON object)
#
# Source of truth: ~/soundbooth-project/SYSTEM-STATE.md
# Livestream verify (browser): https://dashboard.subsplash.com/-d/#/media/live

set -uo pipefail

export DISPLAY="${DISPLAY:-:0}"

# GNOME Wayland: xrandr/window checks need Mutter's Xwayland cookie (not just DISPLAY=:0).
# Same helper used by start-ffmpeg-display (lib name is legacy "vlc-display"; VLC services removed).
if [[ -f "${HOME}/bin/vlc-display-lib.sh" ]]; then
    # shellcheck disable=SC1091
    source "${HOME}/bin/vlc-display-lib.sh"
    soundbooth_export_display_env || true
elif [[ -f "${HOME}/soundbooth-project/audio-routing/scripts/vlc-display-lib.sh" ]]; then
    # shellcheck disable=SC1091
    source "${HOME}/soundbooth-project/audio-routing/scripts/vlc-display-lib.sh"
    soundbooth_export_display_env || true
fi

QUIET=false
JSON=false
for arg in "$@"; do
    case "$arg" in
        --quiet|-q) QUIET=true ;;
        --json) JSON=true ;;
        --help|-h)
            sed -n '2,16p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
    esac
done

# --- config (align with SYSTEM-STATE) ---
# Program target connector (config key still VLC_OUTPUT_CONNECTOR; used by ffplay on DP-4)
PREFERRED_VLC_CONNECTOR="${VLC_OUTPUT_CONNECTOR:-DP-4}"
if [[ -f "${HOME}/.config/soundbooth/vlc-display.conf" ]]; then
    # shellcheck disable=SC1091
    source "${HOME}/.config/soundbooth/vlc-display.conf" 2>/dev/null || true
    PREFERRED_VLC_CONNECTOR="${VLC_OUTPUT_CONNECTOR:-$PREFERRED_VLC_CONNECTOR}"
fi
VIDEO_DEV="${VLC_VIDEO_DEV:-/dev/video0}"
# Network devices (override via env or ~/.config/soundbooth/*.conf)
ATEM_NETWORK_IP="${ATEM_NETWORK_IP:-192.168.2.252}"
CAMERA_NETWORK_IP="${CAMERA_NETWORK_IP:-192.168.1.202}"
if [[ -f "${HOME}/.config/soundbooth/atem.conf" ]]; then
    # shellcheck disable=SC1091
    source "${HOME}/.config/soundbooth/atem.conf" 2>/dev/null || true
    ATEM_NETWORK_IP="${ATEM_NETWORK_IP:-192.168.2.252}"
fi
if [[ -f "${HOME}/.config/soundbooth/camera.conf" ]]; then
    # shellcheck disable=SC1091
    source "${HOME}/.config/soundbooth/camera.conf" 2>/dev/null || true
    CAMERA_NETWORK_IP="${CAMERA_NETWORK_IP:-192.168.1.202}"
fi
EXPECTED_SERVICES=(
    ffmpeg-capture.service
    ffmpeg-display.service
    ffmpeg-display-guard.service
    ffmpeg-srt-watch.service
    livestream-camera-watch.service
    qpwgraph.service
    ensure-audio-routes.service
)
# Optional services: only PASS when active; inactive is silent (not a warn).
# Ardour is off by default — start manually when recording.
# ffmpeg-srt-relay is the Subsplash livestream leg (split from capture 2026-08-23)
# — intentionally stopped between services via stop-live-stream.sh, so its
# absence is not a health problem.
OPTIONAL_SERVICES=(ardour.service ffmpeg-srt-relay.service)
# VLC user units must not exist/run — see check_no_vlc_service.

PASS=0
WARN=0
FAIL=0
declare -a RESULTS=()   # "level|section|message"

log_result() {
    local level="$1" section="$2" msg="$3"
    RESULTS+=("${level}|${section}|${msg}")
    case "$level" in
        PASS) PASS=$((PASS + 1)) ;;
        WARN) WARN=$((WARN + 1)) ;;
        FAIL) FAIL=$((FAIL + 1)) ;;
    esac
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

# --- USB hardware ---
check_usb() {
    local lsusb_out
    lsusb_out=$(lsusb 2>/dev/null || true)

    if echo "$lsusb_out" | grep -qi 'PreSonus.*StudioLive\|StudioLive.*32SX\|194f:0809'; then
        log_result PASS "usb" "PreSonus StudioLive 32SX present"
    else
        log_result FAIL "usb" "PreSonus StudioLive 32SX not found on USB (power on before/with boot)"
    fi

    if echo "$lsusb_out" | grep -qi 'Blackmagic\|1edb:'; then
        log_result PASS "usb" "Blackmagic ATEM present"
    else
        log_result FAIL "usb" "Blackmagic ATEM not found on USB"
    fi
}

# Ping helper: section label, human name, IP. FAIL if unreachable.
check_host_ping() {
    local section="$1" name="$2" ip="$3"
    if [[ -z "$ip" ]]; then
        log_result WARN "$section" "${name}: IP empty; skip network check"
        return
    fi
    if ! have_cmd ping; then
        log_result WARN "$section" "ping not available; skip ${name} network check (${ip})"
        return
    fi
    # 2 probes, 1s timeout each — enough to confirm L3 reachability
    if ping -c 2 -W 1 "$ip" >/dev/null 2>&1; then
        log_result PASS "$section" "${name} reachable at ${ip} (ping)"
    else
        log_result FAIL "$section" "${name} not reachable at ${ip} (ping failed — check Ethernet/power/IP)"
    fi
}

check_atem_network() {
    check_host_ping "atem-net" "ATEM" "${ATEM_NETWORK_IP}"
}

check_camera_network() {
    check_host_ping "camera-net" "Camera" "${CAMERA_NETWORK_IP}"
}

# CMP (PTZOptics preview/control) — optional, not the program path (SDI → ATEM is).
# "active" unit alone does not prove the RTSP→MPEG1 transcode is up; the packed-AppImage
# bug (2026-08-16) left the unit "active" while the pipeline never started ffmpeg/:9999.
CMP_WS_PORT="${CMP_WS_PORT:-9999}"
check_camera_management() {
    local section="camera-mgmt"
    if ! systemctl --user cat camera-management.service &>/dev/null; then
        return
    fi
    local state
    state=$(systemctl --user is-active camera-management.service 2>/dev/null) || true
    state=${state:-unknown}
    if [[ "$state" != "active" ]]; then
        log_result WARN "$section" "camera-management.service: ${state} (CMP/PTZ preview unavailable — not the program path)"
        return
    fi
    log_result PASS "$section" "camera-management.service: active"

    if ! have_cmd ss; then
        log_result WARN "$section" "ss not available; skip CMP :${CMP_WS_PORT} bind check"
        return
    fi
    if ss -tln 2>/dev/null | grep -qE ":${CMP_WS_PORT}([[:space:]]|\$)"; then
        log_result PASS "$section" "CMP RTSP-MPEG websocket bound on :${CMP_WS_PORT}"
    else
        log_result WARN "$section" "camera-management.service active but :${CMP_WS_PORT} not listening (CMP preview likely blank — camera-management-watch.service will restart it automatically after its grace period; manual: systemctl --user restart camera-management, then allow a few minutes)"
    fi
}

# --- Capture device ---
check_video() {
    if [[ -e "$VIDEO_DEV" ]]; then
        log_result PASS "video" "Capture device $VIDEO_DEV exists"
    else
        log_result FAIL "video" "Capture device $VIDEO_DEV missing (wait after ATEM USB cycle, then restart ffmpeg-capture + ffmpeg-display)"
    fi
}

# --- Displays / program target (DP-4 ffplay) ---
check_displays() {
    if ! have_cmd xrandr; then
        log_result WARN "display" "xrandr not available; skip display checks"
        return
    fi

    local mon_list conn_line
    # Re-export in case auth appeared after script start (late graphical session)
    if declare -F soundbooth_export_display_env >/dev/null 2>&1; then
        soundbooth_export_display_env || true
    fi

    local mon_list conn_line
    mon_list=$(xrandr --listmonitors 2>/dev/null || true)
    if [[ -z "$mon_list" ]]; then
        log_result FAIL "display" "No monitors from xrandr (DISPLAY=${DISPLAY:-unset} XAUTHORITY=${XAUTHORITY:-unset})"
        return
    fi

    local count
    count=$(echo "$mon_list" | awk '/^Monitors:/{print $2; exit}')
    log_result PASS "display" "Monitors reported: ${count:-unknown}"

    # Connected connectors from xrandr full output
    local connected
    connected=$(xrandr 2>/dev/null | awk '/ connected/{print $1}' | tr '\n' ' ')
    if echo " $connected " | grep -q " ${PREFERRED_VLC_CONNECTOR} "; then
        log_result PASS "display" "Program target connector ${PREFERRED_VLC_CONNECTOR} connected"
    else
        log_result FAIL "display" "Program target connector ${PREFERRED_VLC_CONNECTOR} not connected (have: ${connected})"
    fi

    for c in DP-1 DP-2 DP-3; do
        if echo " $connected " | grep -q " ${c} "; then
            log_result PASS "display" "Connector ${c} connected"
        else
            log_result WARN "display" "Connector ${c} not connected (FreeShow/booth map may be incomplete)"
        fi
    done

    # Resolve geometry for program connector (DP-4 / ffplay) via shared display lib
    local mon_idx="" mon_geom=""
    if declare -F soundbooth_resolve_vlc_monitor >/dev/null 2>&1; then
        local mon
        mon=$(soundbooth_resolve_vlc_monitor 2>/dev/null || true)
        if [[ -n "$mon" ]]; then
            mon_idx=$(echo "$mon" | awk '{print $1}')
            mon_geom=$(echo "$mon" | awk '{print $3"x"$4"+"$5"+"$6}')
            log_result PASS "display" "Program resolve: connector=${PREFERRED_VLC_CONNECTOR} qt-screen=${mon_idx} geom=${mon_geom}"
        else
            log_result WARN "display" "Could not resolve program monitor via vlc-display-lib"
        fi
    fi

    # Program display: ffmpeg encode + ffplay on preferred connector
    local has_ffmpeg=0 has_ffplay=0
    pgrep -x ffmpeg &>/dev/null && has_ffmpeg=1
    pgrep -x ffplay &>/dev/null && has_ffplay=1

    if [[ $has_ffmpeg -eq 0 ]]; then
        if systemctl --user is-active --quiet ffmpeg-capture.service 2>/dev/null; then
            log_result WARN "program-display" "ffmpeg-capture active but no ffmpeg process yet"
        else
            log_result WARN "program-display" "No FFmpeg process (ffmpeg-capture may be stopped)"
        fi
        return
    fi
    log_result PASS "program-display" "FFmpeg encode process present"

    if [[ $has_ffplay -eq 1 ]]; then
        log_result PASS "program-display" "ffplay display process present (target ${PREFERRED_VLC_CONNECTOR})"
        # Confirm launch args include preferred geometry when possible
        local fp_args
        fp_args=$(ps -eo args= 2>/dev/null | grep -E '[/]ffplay ' | head -1 || true)
        if echo "$fp_args" | grep -qE -- '-left[[:space:]]+0|-left 0' \
            && echo "$fp_args" | grep -qE -- '-top[[:space:]]+1080|-top 1080'; then
            log_result PASS "program-display" "ffplay geometry left=0 top=1080 (DP-4 map)"
        elif [[ -n "$fp_args" ]]; then
            log_result PASS "program-display" "ffplay running (check geometry if TV blank)"
        fi
    else
        if systemctl --user is-active --quiet ffmpeg-display.service 2>/dev/null; then
            log_result WARN "program-display" "ffmpeg-display active but no ffplay process"
        else
            log_result WARN "program-display" "ffplay not running (enable ffmpeg-display.service)"
        fi
    fi
}

# --- User services ---
check_services() {
    local unit state
    for unit in "${EXPECTED_SERVICES[@]}"; do
        if ! systemctl --user cat "$unit" &>/dev/null; then
            log_result FAIL "service" "${unit}: unit file not found"
            continue
        fi
        state=$(systemctl --user is-active "$unit" 2>/dev/null) || true
        state=${state:-unknown}
        if [[ "$state" == "active" ]]; then
            log_result PASS "service" "${unit}: active"
        else
            log_result FAIL "service" "${unit}: ${state} (expected active)"
        fi
    done
    for unit in "${OPTIONAL_SERVICES[@]}"; do
        if ! systemctl --user cat "$unit" &>/dev/null; then
            continue
        fi
        state=$(systemctl --user is-active "$unit" 2>/dev/null) || true
        state=${state:-unknown}
        if [[ "$state" == "active" ]]; then
            log_result PASS "service" "${unit}: active (optional)"
        fi
        # inactive optional units: silent (Ardour off by default is OK)
    done
}

# VLC must never own ATEM capture via systemd. Manual GUI use as a media player is fine.
check_no_vlc_service() {
    local unit
    for unit in vlc.service vlc-display-guard.service; do
        if systemctl --user cat "$unit" &>/dev/null; then
            if systemctl --user is-active --quiet "$unit" 2>/dev/null; then
                log_result FAIL "service" "${unit}: active — steals /dev/video0 from FFmpeg; stop and remove unit"
            elif systemctl --user is-enabled --quiet "$unit" 2>/dev/null; then
                log_result WARN "service" "${unit}: still enabled — disable/remove (program path is FFmpeg)"
            else
                log_result WARN "service" "${unit}: unit file present but inactive — remove leftover from ~/.config/systemd/user/"
            fi
        fi
    done
    if ! systemctl --user cat vlc.service &>/dev/null \
        && ! systemctl --user cat vlc-display-guard.service &>/dev/null; then
        log_result PASS "service" "No VLC user services (manual media player only)"
    fi
}

# FOH path: virtual Mixer must feed Presonus USB returns (today's silent-house failure mode).
check_foh_links() {
    # Preferred FOH path: presonus-foh-bridge (parec Mixer.monitor → ALSA plug →
    # USB 1–2). PipeWire multichannel sinks stick at 0% volume on this board.
    if systemctl --user is-active --quiet presonus-foh-bridge.service 2>/dev/null \
        || { pgrep -x parec >/dev/null 2>&1 && pgrep -x aplay >/dev/null 2>&1; }; then
        if grep -q 'pcm.presonus_foh' "${HOME}/.asoundrc" 2>/dev/null; then
            log_result PASS "foh-graph" "FOH bridge active (Mixer.monitor → ALSA presonus_foh → USB 1–2)"
        else
            log_result WARN "foh-graph" "FOH bridge process up but ~/.asoundrc missing pcm.presonus_foh"
        fi
        return
    fi

    # Fallback: PipeWire Mixer→Presonus links (often silent on 64ch HARDWARE volume)
    if ! have_cmd pw-link; then
        log_result FAIL "foh-graph" "FOH bridge not running and pw-link missing"
        return
    fi
    local links pres
    links=$(pw-link -l 2>/dev/null || true)
    pres=$(pactl list short sinks 2>/dev/null | awk '/PreSonus|StudioLive/ && /output/ {print $2; exit}')
    if [[ -z "${pres:-}" ]]; then
        log_result FAIL "foh-graph" "FOH bridge inactive and no PreSonus PW sink — start presonus-foh-bridge"
        return
    fi

    local fl_ok=0 fr_ok=0
    if echo "$links" | awk '
        /Mixer:monitor_FL/ { getline; if ($0 ~ /playback_AUX0|playback_1|playback_FL/) ok=1 }
        /playback_AUX0|:playback_1|playback_FL/ { getline; if ($0 ~ /Mixer:monitor_FL/) ok=1 }
        END { exit !ok }
    '; then
        fl_ok=1
    fi
    if echo "$links" | awk '
        /Mixer:monitor_FR/ { getline; if ($0 ~ /playback_AUX1|playback_2|playback_FR/) ok=1 }
        /playback_AUX1|:playback_2|playback_FR/ { getline; if ($0 ~ /Mixer:monitor_FR/) ok=1 }
        END { exit !ok }
    '; then
        fr_ok=1
    fi

    if [[ "$fl_ok" -eq 1 && "$fr_ok" -eq 1 ]]; then
        log_result WARN "foh-graph" "Mixer → PreSonus PW links only (prefer presonus-foh-bridge; PW volume often 0%)"
    else
        log_result FAIL "foh-graph" "FOH path down — systemctl --user start presonus-foh-bridge"
    fi
}

# --- PipeWire / Pulse sinks ---
check_audio() {
    if ! have_cmd pactl; then
        log_result FAIL "audio" "pactl not available"
        return
    fi

    local sinks
    sinks=$(pactl list short sinks 2>/dev/null || true)
    if [[ -z "$sinks" ]]; then
        log_result FAIL "audio" "No Pulse/PipeWire sinks"
        return
    fi

    if echo "$sinks" | grep -qi 'Mixer'; then
        log_result PASS "audio" "Virtual sink 'Mixer' present"
    else
        log_result FAIL "audio" "Virtual sink 'Mixer' missing (virtual-audio / null sinks?)"
    fi

    # PreSonus may be owned by ALSA bridge (not a PipeWire sink) — either is OK
    if echo "$sinks" | grep -qi 'PreSonus\|StudioLive\|presonus'; then
        log_result PASS "audio" "PreSonus PipeWire sink present"
    elif lsusb 2>/dev/null | grep -qi 'PreSonus\|StudioLive\|194f:0809'; then
        if systemctl --user is-active --quiet presonus-foh-bridge.service 2>/dev/null; then
            log_result PASS "audio" "PreSonus USB present (FOH via ALSA bridge, not PW sink)"
        else
            log_result WARN "audio" "PreSonus USB present but no PW sink / FOH bridge inactive"
        fi
    else
        log_result FAIL "audio" "PreSonus not found (USB/power?)"
    fi

    # LocalLive = VLC program → HDMI bus; System virtual sink was removed (unused)
    if echo "$sinks" | grep -qi 'LocalLive'; then
        log_result PASS "audio" "Virtual sink 'LocalLive' present (program/TV path)"
    else
        log_result WARN "audio" "Virtual sink 'LocalLive' not found (optional program bus)"
    fi
    if echo "$sinks" | grep -qiE '(^| )System($| )|node.name = "System"'; then
        # leftover null-sink from older configs — not used
        log_result WARN "audio" "Legacy virtual sink 'System' still present (safe to remove; unused)"
    fi

    local def_sink
    def_sink=$(pactl get-default-sink 2>/dev/null || pactl info 2>/dev/null | awk -F': ' '/Default Sink/{print $2}')
    if [[ -z "$def_sink" ]]; then
        log_result WARN "audio" "Could not read default sink"
    elif echo "$def_sink" | grep -qiE 'Mixer|PreSonus|StudioLive'; then
        log_result PASS "audio" "Default sink is board path: ${def_sink}"
    else
        log_result WARN "audio" "Default sink is NOT Mixer/Presonus: ${def_sink} (apps without WP rules may go to speakers)"
    fi

    # WirePlumber policy file
    local wp_live="${HOME}/.config/wireplumber/main.lua.d/50-soundbooth-software-to-mixer.lua"
    if [[ -f "$wp_live" ]]; then
        log_result PASS "audio" "WirePlumber software→Mixer rule installed"
    else
        log_result WARN "audio" "WirePlumber rule missing at ${wp_live}"
    fi

    # Active non-VLC sink inputs: warn if not on Mixer/Presonus
    local bad_routes=0 total_sw=0
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local sid app sink
        sid=$(echo "$line" | cut -f1)
        sink=$(echo "$line" | cut -f2)
        app=$(echo "$line" | cut -f3-)
        app_l=$(echo "$app" | tr '[:upper:]' '[:lower:]')
        # Program TV (ffplay/ffmpeg/vlc) and session noise must not be forced to Mixer
        if echo "$app_l" | grep -qiE 'vlc|ffplay|ffmpeg|mutter|speech-dispatcher|chrome_input'; then
            continue
        fi
        # skip empty / internal
        [[ -z "$app" ]] && continue
        total_sw=$((total_sw + 1))
        # sink id → name (4294967295 = unset / graph-managed in PipeWire)
        local sink_name
        if [[ "$sink" == "4294967295" ]]; then
            sink_name="(unset/graph)"
            # Best-effort: look for app in pw-link toward Mixer
            if have_cmd pw-link && pw-link -l 2>/dev/null | grep -i "${app}" | grep -qi 'Mixer\|Presonus\|StudioLive'; then
                log_result PASS "audio-route" "Stream '${app}' appears linked toward Mixer/Presonus (pw-link)"
            else
                log_result WARN "audio-route" "Stream '${app}' has no Pulse sink (id unset); check qpwgraph / ensure-audio-routes.sh"
                bad_routes=$((bad_routes + 1))
            fi
            continue
        fi
        sink_name=$(echo "$sinks" | awk -v id="$sink" '$1==id {print $2; exit}')
        if echo "${sink_name}" | grep -qiE 'Mixer|PreSonus|StudioLive'; then
            log_result PASS "audio-route" "Stream '${app}' → ${sink_name}"
        else
            bad_routes=$((bad_routes + 1))
            log_result WARN "audio-route" "Stream '${app}' on ${sink_name:-sink#$sink} (want Mixer/Presonus); try ensure-audio-routes.sh"
        fi
    done < <(
        # tab-separated: input_id sink_id app_name (portable awk, no gawk arrays)
        pactl list sink-inputs 2>/dev/null | awk '
            BEGIN { id=""; sink=""; app="" }
            /^Sink Input #/ {
                if (id != "" && app != "") print id "\t" sink "\t" app
                id=$3; gsub("#","",id); sink=""; app=""
            }
            /application\.name/ {
                # extract "value" after =
                n = index($0, "\"")
                if (n > 0) {
                    s = substr($0, n + 1)
                    m = index(s, "\"")
                    if (m > 0) app = substr(s, 1, m - 1)
                }
            }
            /^[[:space:]]*Sink:[[:space:]]/ { sink=$2 }
            END {
                if (id != "" && app != "") print id "\t" sink "\t" app
            }
        '
    )

    if [[ "$total_sw" -eq 0 ]]; then
        log_result PASS "audio-route" "No software playback streams active (nothing to route-check)"
    fi
}

# --- FFmpeg encode / program pipeline health ---
check_vlc_journal() {
    local ff_pid ff_cpu
    if systemctl --user is-active --quiet ffmpeg-capture.service 2>/dev/null; then
        ff_pid=$(systemctl --user show ffmpeg-capture.service -p MainPID --value 2>/dev/null || true)
        if [[ -n "$ff_pid" && "$ff_pid" != "0" ]]; then
            ff_cpu=$(ps -p "$ff_pid" -o pcpu= 2>/dev/null | tr -d ' ' || echo 0)
            ff_cpu=${ff_cpu%%.*}
            ff_cpu=${ff_cpu:-0}
            if [[ "$ff_cpu" -ge 300 ]]; then
                log_result WARN "ffmpeg-capture" "FFmpeg CPU ~${ff_cpu}% (pid ${ff_pid}) — encode heavy"
            else
                log_result PASS "ffmpeg-capture" "ffmpeg-capture active (pid ${ff_pid}, CPU ~${ff_cpu}%)"
            fi
            if pgrep -x ffmpeg &>/dev/null; then
                log_result PASS "ffmpeg-capture" "FFmpeg process present (local UDP; livestream relay is a separate process)"
            else
                log_result WARN "ffmpeg-capture" "Unit active but no ffmpeg process"
            fi
        fi
        if have_cmd ss && ss -uln 2>/dev/null | grep -qE '127\.0\.0\.1:5000|:5000'; then
            log_result PASS "stream" "Local MPEG-TS UDP on :5000 (ffplay feed)"
        else
            # Producer may not show as listen; still OK if ffmpeg + ffplay running
            if pgrep -x ffplay &>/dev/null; then
                log_result PASS "stream" "ffplay consuming program feed"
            else
                log_result WARN "stream" "No UDP :5000 / ffplay feed observed"
            fi
        fi
    elif systemctl --user is-enabled --quiet ffmpeg-capture.service 2>/dev/null; then
        log_result WARN "ffmpeg-capture" "ffmpeg-capture.service enabled but not active"
    fi
}

# --- Program livestream audio (catches intermittent ATEM/ALSA dropouts) ---
# Historical failure (2026-07): ALSA buffer xrun → underrun → "cannot recover" → broken pipe
# on plughw:Extreme,0 while video continued → Subsplash/TV intermittent or silent audio.
check_ffmpeg_program_audio() {
    local section="program-audio"
    local ff_cmd ff_pid since_arg xrun_n underrun_n broken_n demux_n total_bad

    if ! systemctl --user is-active --quiet ffmpeg-capture.service 2>/dev/null; then
        return
    fi

    ff_pid=$(systemctl --user show ffmpeg-capture.service -p MainPID --value 2>/dev/null || true)
    ff_cmd=$(ps -p "${ff_pid:-0}" -o args= 2>/dev/null || pgrep -af '[f]fmpeg' | head -1 || true)

    # 1) Pipeline shape: must open ATEM audio + encode AAC
    if echo "$ff_cmd" | grep -qiE 'plughw:Extreme|hw:Extreme|-f alsa|-f pulse'; then
        log_result PASS "$section" "FFmpeg has ATEM audio input (ALSA/Pulse) in cmdline"
    else
        log_result FAIL "$section" "FFmpeg cmdline missing ATEM audio input (video-only risk)"
    fi
    if echo "$ff_cmd" | grep -qiE 'aac|-c:a'; then
        log_result PASS "$section" "FFmpeg encodes audio (aac / -c:a present)"
    else
        log_result FAIL "$section" "FFmpeg cmdline has no audio encoder — stream will be silent"
    fi
    if echo "$ff_cmd" | grep -qiE 'aresample|async'; then
        log_result PASS "$section" "Audio clock drift compensation present (aresample/async)"
    else
        log_result WARN "$section" "No aresample/async in FFmpeg filter — USB clock drift may cause intermittent audio"
    fi

    # 2) ATEM USB audio hardware visible
    if have_cmd arecord && arecord -l 2>/dev/null | grep -qiE 'Extreme|ATEM|Blackmagic'; then
        log_result PASS "$section" "ATEM USB audio card present (arecord -l)"
    else
        log_result FAIL "$section" "ATEM USB audio card not listed — intermittent/no program audio likely"
    fi

    # 3) Journal: ALSA xrun / underrun / broken pipe since this unit start (or 2h)
    since_arg="2 hours ago"
    local active_ts
    active_ts=$(systemctl --user show ffmpeg-capture.service -p ActiveEnterTimestamp --value 2>/dev/null || true)
    if [[ -n "$active_ts" && "$active_ts" != "n/a" ]]; then
        since_arg="$active_ts"
    fi
    local jlog
    jlog=$(journalctl --user -u ffmpeg-capture.service --since "$since_arg" --no-pager 2>/dev/null || true)
    # Count ALSA-specific failures only (do not treat SRT 401 "Input/output error" as audio path death)
    xrun_n=$(echo "$jlog" | grep -ciE 'ALSA buffer xrun|ALSA read error' || true)
    underrun_n=$(echo "$jlog" | grep -ciE 'cannot recover from underrun|snd_pcm_prepare failed' || true)
    broken_n=$(echo "$jlog" | grep -ciE 'ALSA.*Broken pipe|Broken pipe' || true)
    demux_n=$(echo "$jlog" | grep -ciE 'in#1/alsa|\[alsa @' | grep -ciE 'Error during demuxing|Input/output error|Broken pipe' || true)
    xrun_n=${xrun_n:-0}
    underrun_n=${underrun_n:-0}
    broken_n=${broken_n:-0}
    demux_n=${demux_n:-0}
    total_bad=$((xrun_n + underrun_n + demux_n + broken_n))

    if [[ "$total_bad" -eq 0 ]]; then
        log_result PASS "$section" "No ALSA xrun/underrun demux errors in journal since process start"
    elif [[ "$underrun_n" -gt 0 || "$demux_n" -gt 0 || "$broken_n" -gt 0 ]]; then
        log_result FAIL "$section" "Program audio path failed in journal (xrun=${xrun_n} underrun=${underrun_n} alsa-broken=${broken_n} demux=${demux_n}) — restart: systemctl --user restart ffmpeg-capture"
    elif [[ "$xrun_n" -ge 3 ]]; then
        log_result WARN "$section" "Repeated ALSA buffer xruns (${xrun_n}) since start — audio may go intermittent"
    elif [[ "$xrun_n" -gt 0 ]]; then
        log_result WARN "$section" "ALSA buffer xrun seen (${xrun_n}) — watch for intermittent program audio"
    fi

    # 4) Sample local MPEG-TS for audio packets (only if nothing holds exclusive UDP bind,
    #    or use a short decode that shares — skip exclusive probe if ffplay owns the port)
    local udp_busy=0
    if have_cmd ss && ss -ulnp 2>/dev/null | grep -qE ':5000'; then
        if pgrep -x ffplay &>/dev/null; then
            udp_busy=1
        fi
    fi
    if [[ $udp_busy -eq 1 ]]; then
        log_result PASS "$section" "Local feed in use by ffplay (skip exclusive UDP audio sample)"
    elif have_cmd ffmpeg && systemctl --user is-active --quiet ffmpeg-capture.service; then
        local sample_out audio_kb
        sample_out=$(timeout 5 ffmpeg -hide_banner -loglevel error \
            -i "udp://@127.0.0.1:5000?fifo_size=1000000&overrun_nonfatal=1&timeout=3000000" \
            -t 2 -vn -f null - 2>&1 || true)
        # If we got size= with audio, good; if only errors, warn
        if echo "$sample_out" | grep -qiE 'error|Invalid|bind failed'; then
            log_result WARN "$section" "Could not sample local UDP for audio (bind/stream busy or down)"
        else
            log_result PASS "$section" "Local UDP feed accepts short audio-only sample (or idle)"
        fi
    fi

    # 5) TV path: ffplay audio must not be on Mixer (FOH)
    if pgrep -x ffplay &>/dev/null && have_cmd pactl; then
        local mixer_id ff_on_mixer=0 ff_on_hdmi=0 ff_found=0 sink_id sink_name
        mixer_id=$(pactl list short sinks 2>/dev/null | awk '$2=="Mixer"{print $1; exit}')
        while read -r line; do
            # format: id sink client ...
            local iid isink
            iid=$(echo "$line" | awk '{print $1}')
            isink=$(echo "$line" | awk '{print $2}')
            local bin
            bin=$(pactl list sink-inputs 2>/dev/null | awk -v want="$iid" '
                $1=="Sink" && $2=="Input" { cur=$3; gsub("#","",cur) }
                cur==want && /application.process.binary/ {
                    line=$0; sub(/[^"]*"/, "", line); sub(/".*/, "", line); print line; exit
                }
            ')
            [[ "$bin" == "ffplay" ]] || continue
            ff_found=1
            sink_name=$(pactl list short sinks 2>/dev/null | awk -v s="$isink" '$1==s{print $2; exit}')
            if [[ "$isink" == "$mixer_id" || "$sink_name" == "Mixer" ]]; then
                ff_on_mixer=1
            fi
            if echo "$sink_name" | grep -qiE 'hdmi-stereo|pro-output-7|LocalLive'; then
                ff_on_hdmi=1
            fi
        done < <(pactl list short sink-inputs 2>/dev/null || true)
        if [[ $ff_found -eq 0 ]]; then
            log_result WARN "$section" "ffplay running but no Pulse sink-input (audio may be silent or non-Pulse)"
        elif [[ $ff_on_mixer -eq 1 ]]; then
            log_result FAIL "$section" "ffplay audio is on Mixer (FOH) — should be HDMI TV; run ensure-audio-routes / restart ffmpeg-display"
        elif [[ $ff_on_hdmi -eq 1 ]]; then
            log_result PASS "$section" "ffplay audio routed to HDMI/LocalLive (not Mixer)"
        else
            log_result WARN "$section" "ffplay audio on unexpected sink (not Mixer, not recognized HDMI)"
        fi
    fi
}

# --- Session autostart + browser placement (Sunday boot apps) ---
check_booth_session_apps() {
    local section="session-apps"
    local autostart="${XDG_CONFIG_HOME:-$HOME/.config}/autostart"
    local f missing=0
    local booth_x vivaldi_x

    for f in soundbooth-spotify.desktop soundbooth-freeshow.desktop soundbooth-browser.desktop soundbooth-dashboard.desktop; do
        if [[ -f "${autostart}/${f}" ]]; then
            log_result PASS "$section" "Autostart ${f} installed"
        else
            log_result WARN "$section" "Autostart missing ${f} — run ~/bin/install-booth-autostart.sh"
            missing=1
        fi
    done

    if [[ -x "${HOME}/bin/start-booth-browser.sh" ]]; then
        log_result PASS "$section" "start-booth-browser.sh present (forces DP-1)"
    else
        log_result WARN "$section" "start-booth-browser.sh missing — browser may open on DP-4"
    fi

    if [[ -x "${HOME}/bin/start-freeshow.sh" ]]; then
        log_result PASS "$section" "start-freeshow.sh present"
    else
        log_result WARN "$section" "start-freeshow.sh missing"
    fi

    # If Vivaldi is running, warn if its window is on program HDMI (DP-4) region
    if have_cmd xrandr && have_cmd xwininfo; then
        booth_x=$(xrandr --query 2>/dev/null | awk '
            $1=="DP-1" && / connected/ {
                for (i=1;i<=NF;i++) if ($i ~ /^[0-9]+x[0-9]+\+[0-9]+\+[0-9]+$/) {
                    split($i, a, /[x+]/); print a[3]; exit
                }
            }')
        if [[ -n "$booth_x" ]] && xwininfo -root -tree 2>/dev/null | grep -qi 'vivaldi'; then
            # Largest Vivaldi-ish window absolute X
            vivaldi_x=$(xwininfo -root -tree 2>/dev/null | awk '
                /[Vv]ivaldi/ && /[0-9]+x[0-9]+\+[0-9]+\+[0-9]+/ {
                    for (i=1;i<=NF;i++) if ($i ~ /^[0-9]+x[0-9]+\+[0-9]+\+[0-9]+$/) {
                        split($i, a, /[x+]/);
                        w=a[1]+0; h=a[2]+0; x=a[3]+0;
                        if (w>400 && h>300 && w*h > best) { best=w*h; bx=x }
                    }
                }
                END { if (best>0) print bx }
            ')
            if [[ -n "$vivaldi_x" ]]; then
                if [[ "$vivaldi_x" -ge "$booth_x" ]]; then
                    log_result PASS "$section" "Vivaldi window on booth side (x=${vivaldi_x} ≥ DP-1 x=${booth_x})"
                else
                    log_result WARN "$section" "Vivaldi appears left of DP-1 (x=${vivaldi_x}; may be on DP-4) — use ~/bin/start-booth-browser.sh"
                fi
            fi
        fi
    fi

    # Display env readiness for headless/systemd-launched diagnostics
    if [[ -n "${XAUTHORITY:-}" && -f "${XAUTHORITY}" ]]; then
        log_result PASS "$section" "XAUTHORITY set for display checks (${XAUTHORITY##*/})"
    else
        log_result WARN "$section" "XAUTHORITY unset — display/session-app window checks may false-fail"
    fi
}

# --- Output ---
print_human() {
    $QUIET && return
    echo "=== Soundbooth health $(date -Iseconds) ==="
    echo "Policy: software → Mixer/Presonus; program → FFmpeg SRT + ffplay on ${PREFERRED_VLC_CONNECTOR}; capture ${VIDEO_DEV}"
    echo
    local prev=""
    local r level section msg
    for r in "${RESULTS[@]}"; do
        level="${r%%|*}"
        rest="${r#*|}"
        section="${rest%%|*}"
        msg="${rest#*|}"
        if [[ "$section" != "$prev" ]]; then
            echo "--- ${section} ---"
            prev="$section"
        fi
        case "$level" in
            PASS) printf '  [\033[32mPASS\033[0m] %s\n' "$msg" ;;
            WARN) printf '  [\033[33mWARN\033[0m] %s\n' "$msg" ;;
            FAIL) printf '  [\033[31mFAIL\033[0m] %s\n' "$msg" ;;
            *)    printf '  [%s] %s\n' "$level" "$msg" ;;
        esac
    done
    echo
    echo "Summary: ${PASS} pass, ${WARN} warn, ${FAIL} fail"
    echo "Hints:"
    echo "  FOH silent (apps on Mixer, no board):  ~/bin/ensure-audio-routes.sh"
    echo "  Default sink:                         pactl set-default-sink Mixer"
    echo "  Program TV / capture:                  systemctl --user restart ffmpeg-capture ffmpeg-display"
    echo "  Program audio xruns:                  journalctl --user -u ffmpeg-capture -b | grep -iE 'alsa|xrun'"
    echo "  End livestream now:                   ~/bin/stop-live-stream.sh"
    echo "  (Re)start livestream:                 ~/bin/start-live-stream.sh"
    echo "  Browser on DP-1:                      ~/bin/start-booth-browser.sh"
    echo "  Dashboard on workspace 2:             ~/bin/start-booth-dashboard-view.sh"
    echo "  Dashboard workspace patch:            ~/bin/configure-dashboard-workspace.sh"
    echo "  Autostart refresh:                    ~/bin/install-booth-autostart.sh"
    echo "  Livestream verify (browser):          https://dashboard.subsplash.com/-d/#/media/live"
    echo "  Eyeball outputs: use the control dashboard's HDMI preview tiles (Super+Alt+2)"
}

print_json() {
    # Minimal JSON without jq dependency
    echo -n '{"pass":'"$PASS"',"warn":'"$WARN"',"fail":'"$FAIL"',"checks":['
    local first=1 r level section msg
    for r in "${RESULTS[@]}"; do
        level="${r%%|*}"
        rest="${r#*|}"
        section="${rest%%|*}"
        msg="${rest#*|}"
        # escape quotes in msg
        msg=${msg//\\/\\\\}
        msg=${msg//\"/\\\"}
        [[ $first -eq 1 ]] || echo -n ','
        first=0
        printf '{"level":"%s","section":"%s","message":"%s"}' "$level" "$section" "$msg"
    done
    echo ']}'
}

print_quiet_summary() {
    echo "soundbooth-health: pass=${PASS} warn=${WARN} fail=${FAIL}"
}

# --- run ---
# SOUNDBOOTH_HEALTH_SELFTEST=1: skip run+exit so tests can `source` this file
# and call individual check_* functions directly against faked PATH commands.
# See audio-routing/tests/health-check-unit-tests.sh. Unset (normal use) is
# a no-op change — behavior below is identical to before this guard existed.
if [[ "${SOUNDBOOTH_HEALTH_SELFTEST:-0}" != "1" ]]; then

check_usb
check_atem_network
check_camera_network
check_camera_management
check_video
check_displays
check_services
check_no_vlc_service
check_audio
check_foh_links
check_vlc_journal
check_ffmpeg_program_audio
check_booth_session_apps

if $JSON; then
    print_json
elif $QUIET; then
    print_quiet_summary
else
    print_human
fi

if [[ "$FAIL" -gt 0 ]]; then
    exit 2
elif [[ "$WARN" -gt 0 ]]; then
    exit 1
fi
exit 0

fi

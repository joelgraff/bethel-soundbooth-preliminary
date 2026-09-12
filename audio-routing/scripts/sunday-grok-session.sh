#!/bin/bash
# On Sunday boots / graphical logins, open an interactive Grok session in a
# terminal for live soundbooth troubleshooting (after network + services settle).
#
# Install: ~/bin/sunday-grok-session.sh + sunday-grok.service (user)
# Disable: systemctl --user disable sunday-grok.service
#          or SOUNDBOOTH_SUNDAY_GROK=0 in environment / conf
# Test any day: SOUNDBOOTH_SUNDAY_GROK_FORCE=1 ~/bin/sunday-grok-session.sh

set -euo pipefail

export PATH="${HOME}/bin:${HOME}/.grok/bin:${PATH:-/usr/bin}"
export DISPLAY="${DISPLAY:-:0}"

CONF="${SOUNDBOOTH_SUNDAY_GROK_CONF:-$HOME/.config/soundbooth/sunday-grok.conf}"
if [[ -f "$CONF" ]]; then
    # shellcheck disable=SC1090
    source "$CONF"
fi

# Master switch (default on)
if [[ "${SOUNDBOOTH_SUNDAY_GROK:-1}" == "0" ]]; then
    echo "sunday-grok: disabled (SOUNDBOOTH_SUNDAY_GROK=0)"
    exit 0
fi

# ISO weekday: 1=Mon … 7=Sun
dow=$(date +%u)
if [[ "${SOUNDBOOTH_SUNDAY_GROK_FORCE:-0}" != "1" && "$dow" != "7" ]]; then
    echo "sunday-grok: not Sunday (dow=${dow}) — skip"
    exit 0
fi

# Once per boot (not once per calendar day — reboot must re-launch Grok).
# boot_id changes every reboot; re-login same boot still skips unless FORCE.
stamp_dir="${XDG_CACHE_HOME:-$HOME/.cache}/soundbooth"
mkdir -p "$stamp_dir"
boot_id=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo "noboot")
stamp="${stamp_dir}/sunday-grok-boot-${boot_id}.stamp"
if [[ -f "$stamp" && "${SOUNDBOOTH_SUNDAY_GROK_FORCE:-0}" != "1" ]]; then
    echo "sunday-grok: already launched this boot ($stamp) — skip"
    exit 0
fi
# Clean old calendar-day stamps (legacy) and previous boot stamps (keep last few)
rm -f "${stamp_dir}"/sunday-grok-????-??-??.stamp 2>/dev/null || true
find "$stamp_dir" -maxdepth 1 -name 'sunday-grok-boot-*.stamp' ! -name "sunday-grok-boot-${boot_id}.stamp" -mtime +7 -delete 2>/dev/null || true

tmp_dir="${XDG_RUNTIME_DIR:-/tmp}"

PROJECT="${SOUNDBOOTH_PROJECT:-$HOME/soundbooth-project}"
GROK_BIN="${GROK_BIN:-$HOME/.grok/bin/grok}"
if [[ ! -x "$GROK_BIN" ]]; then
    GROK_BIN=$(command -v grok || true)
fi
if [[ -z "$GROK_BIN" || ! -x "$GROK_BIN" ]]; then
    echo "sunday-grok: grok binary not found" >&2
    exit 1
fi

TERM_BIN=""
for c in gnome-terminal x-terminal-emulator kgx ptyxis; do
    if command -v "$c" &>/dev/null; then
        TERM_BIN=$(command -v "$c")
        break
    fi
done
if [[ -z "$TERM_BIN" ]]; then
    echo "sunday-grok: no terminal emulator found" >&2
    exit 1
fi

# Wait for networking (default route + DNS) — cold boots often lag WAN/DNS
NET_WAIT="${SOUNDBOOTH_SUNDAY_GROK_NET_WAIT:-180}"
if [[ "${NET_WAIT}" -gt 0 ]]; then
    echo "sunday-grok: waiting up to ${NET_WAIT}s for network (default route + DNS)..."
    net_ok=0
    for i in $(seq 1 "$NET_WAIT"); do
        if ip -4 route show default 2>/dev/null | grep -q . \
            && ( getent hosts live-rs.subsplash.com &>/dev/null \
                 || getent hosts one.one.one.one &>/dev/null \
                 || getent hosts 1.1.1.1 &>/dev/null ); then
            # Prefer real hostname resolution for livestream
            if getent hosts live-rs.subsplash.com &>/dev/null \
                || getent hosts one.one.one.one &>/dev/null; then
                echo "sunday-grok: network ready after ${i}s"
                net_ok=1
                break
            fi
        fi
        sleep 1
    done
    if [[ "$net_ok" -ne 1 ]]; then
        echo "sunday-grok: network not fully ready after ${NET_WAIT}s — continuing anyway" >&2
    fi
fi

# Extra settle for FFmpeg / displays after network (override with conf)
DELAY="${SOUNDBOOTH_SUNDAY_GROK_DELAY:-20}"
if [[ "${DELAY}" -gt 0 ]]; then
    echo "sunday-grok: waiting ${DELAY}s for booth services to settle..."
    sleep "$DELAY"
fi

# Soft-wait for encode path (do not fail if still starting)
if systemctl --user is-active --quiet ffmpeg-capture.service 2>/dev/null; then
    echo "sunday-grok: ffmpeg-capture is active"
else
    echo "sunday-grok: ffmpeg-capture not active yet (health will report)"
fi

PROMPT="${SOUNDBOOTH_SUNDAY_GROK_PROMPT:-/soundbooth Sunday service boot. Run ~/bin/soundbooth-health.sh and summarize pass/warn/fail with concrete fixes. Stay ready to troubleshoot audio routing, FFmpeg SRT/ffplay DP-4, ATEM, FreeShow, and displays. Prefer SYSTEM-STATE.md policies.}"

# shell wrapper so PATH and cwd are correct inside the terminal
run_script=$(mktemp "${tmp_dir}/sunday-grok-run.XXXXXX.sh")
cat >"$run_script" <<EOF
#!/bin/bash
export PATH="${HOME}/bin:${HOME}/.grok/bin:\${PATH:-/usr/bin}"
cd "$PROJECT" || exit 1
echo "=== Soundbooth Sunday Grok ==="
echo "Project: $PROJECT"
echo "Health:  ~/bin/soundbooth-health.sh"
echo "Quit:    /quit   |  New: /new"
echo
exec "$GROK_BIN" --cwd "$PROJECT" --experimental-memory $(printf '%q' "$PROMPT")
EOF
chmod +x "$run_script"

echo "sunday-grok: launching terminal + Grok"
case "$(basename "$TERM_BIN")" in
    gnome-terminal)
        "$TERM_BIN" \
            --title="Soundbooth Sunday — Grok" \
            --working-directory="$PROJECT" \
            -- "$run_script" &
        ;;
    *)
        "$TERM_BIN" -e "$run_script" &
        ;;
esac

touch "$stamp"
# Clean runner after a bit (terminal has started)
( sleep 120; rm -f "$run_script" ) &
disown || true

echo "sunday-grok: started (stamp=$stamp)"
exit 0

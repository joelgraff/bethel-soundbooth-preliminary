#!/bin/bash
# Soundbooth Audacity launcher
#
# Default: system Audacity via ALSA/Pulse (Mixer → Presonus). Does NOT require
# real JACK or pw-jack.
#
# Multi-channel board ports: start-audacity.sh --jack  (uses pw-jack → PipeWire)
#
# Mitigations for this booth (GNOME Wayland + PipeWire + jackd2 packages):
#   - JACK_NO_START_SERVER=1 so PortAudio does not try to spawn jackd
#   - Prefer /usr/bin/audacity over AppImage (AppImage pollutes ModulePath)
#   - Strip stale /tmp/.mount_audaci* module paths from audacity.cfg
#   - Stop stray jackdbus before start (D-Bus activated by jackd2)
#   - GDK_BACKEND=x11 for more reliable wx windowing under Wayland

set -euo pipefail

export DISPLAY="${DISPLAY:-:0}"
if [[ -z "${XAUTHORITY:-}" ]]; then
  xa=$(ls /run/user/"$(id -u)"/.mutter-Xwaylandauth.* 2>/dev/null | head -1 || true)
  [[ -n "${xa}" ]] && export XAUTHORITY="$xa"
fi
export GDK_BACKEND="${GDK_BACKEND:-x11}"
export JACK_NO_START_SERVER=1
export NO_AT_BRIDGE="${NO_AT_BRIDGE:-1}"
export UBUNTU_MENUPROXY="${UBUNTU_MENUPROXY:-0}"

USE_JACK=0
if [[ "${1:-}" == "--jack" || "${1:-}" == "-j" ]]; then
  USE_JACK=1
  shift
elif [[ "${SOUNDBOOTH_AUDACITY_JACK:-0}" == "1" ]]; then
  USE_JACK=1
fi

AUDACITY_BIN="${SOUNDBOOTH_AUDACITY_BIN:-/usr/bin/audacity}"
if [[ ! -x "$AUDACITY_BIN" ]]; then
  # Fallback AppImage only if system package missing
  if [[ -x "$HOME/AppImage/audacity-linux-3.7.7-x64-22.04.AppImage" ]]; then
    AUDACITY_BIN="$HOME/AppImage/audacity-linux-3.7.7-x64-22.04.AppImage"
  else
    echo "ERROR: audacity not found" >&2
    exit 1
  fi
fi

# Already running → try to raise, do not start a second instance (can hang)
if pgrep -x audacity >/dev/null 2>&1; then
  if command -v wmctrl >/dev/null 2>&1; then
    wmctrl -xa audacity.Audacity 2>/dev/null || wmctrl -a Audacity 2>/dev/null || true
  fi
  echo "Audacity already running: $(pgrep -x audacity | tr '\n' ' ')"
  exit 0
fi

# Clean dead AppImage module paths that can break system Audacity startup
CFG="${XDG_CONFIG_HOME:-$HOME/.config}/audacity/audacity.cfg"
if [[ -f "$CFG" ]] && grep -q '\.mount_audaci' "$CFG" 2>/dev/null; then
  cp -a "$CFG" "${CFG}.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
  python3 - "$CFG" <<'PY' 2>/dev/null || true
import re, sys
from pathlib import Path
p = Path(sys.argv[1])
text = p.read_text(encoding="utf-8", errors="replace")
# Drop ModulePath lines pointing at vanished AppImage mounts
text2 = re.sub(
    r"(?m)^mod-[^=]+=/tmp/\.mount_audaci[^\n]*\n",
    "",
    text,
)
# Disable cloud/musehub modules that lived only in AppImage
text2 = re.sub(r"(?m)^(mod-cloud-audiocom|mod-musehub-ui|mod-midi-import-export)=1\s*$", r"\1=0", text2)
if text2 != text:
    p.write_text(text2, encoding="utf-8")
    print(f"Cleaned AppImage module paths in {p}")
PY
fi

# jackdbus is D-Bus activated (org.jackaudio.service). If present without a
# running server it confuses JACK probes. Safe to stop for desktop use.
if pgrep -x jackdbus >/dev/null 2>&1; then
  killall -q jackdbus 2>/dev/null || true
  sleep 0.2
fi

if [[ "$USE_JACK" -eq 1 ]]; then
  if ! command -v pw-jack >/dev/null 2>&1; then
    echo "ERROR: pw-jack missing (install pipewire-jack)" >&2
    exit 1
  fi
  echo "Starting Audacity with PipeWire JACK bridge (pw-jack)..."
  # Prefer JACK host once multi-channel is desired (user can still change in UI)
  exec pw-jack env JACK_NO_START_SERVER=1 "$AUDACITY_BIN" "$@"
fi

echo "Starting Audacity (ALSA/Pulse — no JACK required)..."
exec env JACK_NO_START_SERVER=1 "$AUDACITY_BIN" "$@"

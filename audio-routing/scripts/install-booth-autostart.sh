#!/bin/bash
# Install GNOME session autostart for Spotify, FreeShow, browser, and the
# control dashboard (Vivaldi on workspace 2).
# Source: soundbooth-project/audio-routing/autostart/
# Live:   ~/.config/autostart/
#
# Usage:
#   ~/bin/install-booth-autostart.sh           # install / refresh
#   ~/bin/install-booth-autostart.sh --remove  # disable (remove desktops)

set -euo pipefail

SRC="${SOUNDBOOTH_AUTOSTART_SRC:-$HOME/soundbooth-project/audio-routing/autostart}"
DST="${XDG_CONFIG_HOME:-$HOME/.config}/autostart"
FILES=(
    soundbooth-spotify.desktop
    soundbooth-freeshow.desktop
    soundbooth-browser.desktop
    soundbooth-dashboard.desktop
)

if [[ "${1:-}" == "--remove" ]]; then
    for f in "${FILES[@]}"; do
        rm -f "${DST}/${f}"
        echo "Removed ${DST}/${f}"
    done
    echo "Booth app autostart disabled (takes effect next login)."
    exit 0
fi

mkdir -p "$DST"
for f in "${FILES[@]}"; do
    if [[ ! -f "${SRC}/${f}" ]]; then
        echo "ERROR: missing ${SRC}/${f}" >&2
        exit 1
    fi
    install -m 0644 "${SRC}/${f}" "${DST}/${f}"
    echo "Installed ${DST}/${f}"
done

# Ensure FreeShow wrapper is live
if [[ -f "$HOME/soundbooth-project/audio-routing/scripts/start-freeshow.sh" ]]; then
    install -m 0755 "$HOME/soundbooth-project/audio-routing/scripts/start-freeshow.sh" "$HOME/bin/start-freeshow.sh"
fi

# Ensure dashboard-view starter + app desktop (Auto Move / gtk-launch) are live
if [[ -f "$HOME/soundbooth-project/audio-routing/scripts/start-booth-dashboard-view.sh" ]]; then
    install -m 0755 "$HOME/soundbooth-project/audio-routing/scripts/start-booth-dashboard-view.sh" \
        "$HOME/bin/start-booth-dashboard-view.sh"
fi
if [[ -f "$HOME/soundbooth-project/audio-routing/desktop/soundbooth-dashboard.desktop" ]]; then
    mkdir -p "$HOME/.local/share/applications"
    install -m 0644 "$HOME/soundbooth-project/audio-routing/desktop/soundbooth-dashboard.desktop" \
        "$HOME/.local/share/applications/soundbooth-dashboard.desktop"
fi

echo "Done. Autostart applies on next graphical login (or reboot)."
echo "Start now without rebooting:"
echo "  /snap/bin/spotify &"
echo "  ~/bin/start-freeshow.sh &"
echo "  ~/bin/start-booth-browser.sh &        # Vivaldi on DP-1 (not program DP-4)"
echo "  ~/bin/start-booth-dashboard-view.sh & # dashboard on GNOME workspace 2"

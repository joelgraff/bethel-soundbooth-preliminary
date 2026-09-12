#!/bin/bash
# Launch the Soundbooth Control Dashboard in Vivaldi (app mode, own profile),
# on GNOME workspace 2 — replaces booth-multiview's old role of "glanceable
# status view the operator switches to," now that the dashboard's own HDMI
# preview tiles cover what multiview used to show.
#
# Autostart: soundbooth-dashboard.desktop -> this script
# Workspace-2 placement: configure-dashboard-workspace.sh (Mutter-native
# Shell extension — window title match, same mechanism multiview used;
# X11 _NET_WM_DESKTOP/wmctrl/xdotool do not move real Mutter workspaces).
#
# Own Vivaldi profile (separate from start-booth-browser.sh's) so the
# dashboard's PIN-login session persists independently of general browsing.
#
# Local-token auto-login: this is the trusted, physically-local viewer, so
# it skips the PIN screen by passing LOCAL_TOKEN (from dashboard.conf, same
# trust tier as the PIN/session secret) once in the URL — the page exchanges
# it for a real session on load and scrubs it from the address bar. See
# dashboard/backend/app/auth.py for why this isn't a source-IP check.

set -euo pipefail

# shellcheck disable=SC1091
if [[ -f "${HOME}/bin/vlc-display-lib.sh" ]]; then
    source "${HOME}/bin/vlc-display-lib.sh"
    soundbooth_export_display_env || true
fi
export DISPLAY="${DISPLAY:-:0}"

BROWSER="${SOUNDBOOTH_BROWSER:-/usr/bin/vivaldi-stable}"
BASE_URL="${SOUNDBOOTH_DASHBOARD_URL:-http://127.0.0.1:8420/}"
PROFILE_DIR="${SOUNDBOOTH_DASHBOARD_PROFILE:-${HOME}/.config/vivaldi-dashboard}"
DASHBOARD_CONF="${SOUNDBOOTH_DASHBOARD_CONF:-${HOME}/.config/soundbooth/dashboard.conf}"

LOCAL_TOKEN=""
if [[ -f "$DASHBOARD_CONF" ]]; then
    LOCAL_TOKEN=$(grep -E '^LOCAL_TOKEN=' "$DASHBOARD_CONF" | tail -1 | cut -d= -f2- | tr -d '"'"'"'')
fi

DASHBOARD_URL="$BASE_URL"
if [[ -n "$LOCAL_TOKEN" ]]; then
    DASHBOARD_URL="${BASE_URL}?local_token=${LOCAL_TOKEN}"
else
    echo "WARN: no LOCAL_TOKEN in ${DASHBOARD_CONF} — will show the PIN screen" >&2
fi

echo "Dashboard view -> ${BASE_URL} (app mode, workspace 2 via Shell extension)"

exec "$BROWSER" \
    --app="${DASHBOARD_URL}" \
    --user-data-dir="${PROFILE_DIR}" \
    --class=SoundboothDashboard \
    --window-size=1400,1000 \
    "$@"

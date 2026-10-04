#!/bin/bash
# Launch the PTZ camera control widget (direction pad, zoom, named presets) in
# Vivaldi app mode with its own profile. Cockpit widget — see
# docs/dp1-desktop-cockpit-plan.md. Backend: dashboard/backend/app/ptz.py.
#
# Deliberately does NOT position the window: the DP-1 zone layout is not decided
# yet. Place/tile it by hand (Tiling Shell) for now. Native Wayland is fine —
# unlike start-widget-livestream.sh nothing here needs X11 tools.
#
# Same local-token auto-login as start-booth-dashboard-view.sh.

set -euo pipefail

BROWSER="${SOUNDBOOTH_BROWSER:-/usr/bin/vivaldi-stable}"
BASE_URL="${SOUNDBOOTH_DASHBOARD_URL:-http://127.0.0.1:8420/widget-camera.html}"
PROFILE_DIR="${SOUNDBOOTH_WIDGET_CAMERA_PROFILE:-${HOME}/.config/vivaldi-widget-camera}"
DASHBOARD_CONF="${SOUNDBOOTH_DASHBOARD_CONF:-${HOME}/.config/soundbooth/dashboard.conf}"
export DISPLAY="${DISPLAY:-:0}"

LOCAL_TOKEN=""
if [[ -f "$DASHBOARD_CONF" ]]; then
    LOCAL_TOKEN=$(grep -E '^LOCAL_TOKEN=' "$DASHBOARD_CONF" | tail -1 | cut -d= -f2- | tr -d '"'"'")
fi

URL="$BASE_URL"
if [[ -n "$LOCAL_TOKEN" ]]; then
    URL="${BASE_URL}?local_token=${LOCAL_TOKEN}"
else
    echo "WARN: no LOCAL_TOKEN in ${DASHBOARD_CONF} — will show the PIN screen" >&2
fi

exec "$BROWSER" \
    --app="${URL}" \
    --user-data-dir="${PROFILE_DIR}" \
    --class=SoundboothWidgetCamera \
    --window-size=460,760 \
    --password-store=basic \
    "$@"

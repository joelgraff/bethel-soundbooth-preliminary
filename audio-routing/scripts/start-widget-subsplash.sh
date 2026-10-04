#!/bin/bash
# Launch the Subsplash "is the stream actually reaching Subsplash?" view as a
# pinned cockpit widget: Vivaldi app mode on the Subsplash live-media page, own
# profile so its login persists. Cockpit plan: docs/dp1-desktop-cockpit-plan.md.
#
# This is the *remote* confirmation — distinct from the dashboard's LIVESTREAM
# tile, which only shows the local encode leg sent to the SRT relay.
#
# FIRST RUN NEEDS A LOGIN: sign in to Subsplash once in this window (someone at
# the booth; credentials are never stored by this repo). The profile keeps it.
#
# Not positioned (DP-1 zones undecided); tile by hand for now.

set -euo pipefail

BROWSER="${SOUNDBOOTH_BROWSER:-/usr/bin/vivaldi-stable}"
URL="${SOUNDBOOTH_SUBSPLASH_URL:-https://dashboard.subsplash.com/-d/#/media/live}"
PROFILE_DIR="${SOUNDBOOTH_WIDGET_SUBSPLASH_PROFILE:-${HOME}/.config/vivaldi-widget-subsplash}"
export DISPLAY="${DISPLAY:-:0}"

exec "$BROWSER" \
    --app="${URL}" \
    --user-data-dir="${PROFILE_DIR}" \
    --class=SoundboothWidgetSubsplash \
    --window-size=620,800 \
    "$@"

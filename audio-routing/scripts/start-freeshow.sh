#!/bin/bash
# start-freeshow.sh
# Wrapper for FreeShow with tweaks for better media playback on this rig.
#
# WebM/VP9 often stutters because this GPU lacks VP9 hardware decode.
# Prefer MP4/H.264 files. This wrapper can be extended with Electron flags.

set -euo pipefail

# Common Electron flags that sometimes help video on Linux
# (Vaapi may help H264/HEVC even if VP9 is software)
FLAGS=(
    --enable-features=VaapiVideoDecoder
    --use-gl=desktop
)

# If you want to force the deb version or AppImage, edit below.
# Currently uses whatever /usr/bin/freeshow points to.

echo "Launching FreeShow (with accel hints)..."

exec /usr/bin/freeshow "${FLAGS[@]}" "$@"

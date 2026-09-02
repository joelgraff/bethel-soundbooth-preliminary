#!/bin/bash
# Configure GNOME so the Soundbooth Control Dashboard lands on workspace 2.
#
# Replaces configure-multiview-workspace.sh (retired along with booth
# multiview — see dashboard/README.md). Same Wayland-native mechanism,
# repointed at the dashboard's Vivaldi app-mode window instead.
#
# Why not xprop/_NET_WM_DESKTOP?
#   On GNOME Wayland, X11 desktop hints are not applied to real Mutter workspaces.
#   The "Auto Move Windows" extension (already installed) uses native
#   MetaWindow.change_workspace_by_index — that works.
#
# This script:
#   1) Installs soundbooth-dashboard.desktop (StartupWMClass=SoundboothDashboard)
#   2) Ensures ≥2 fixed workspaces
#   3) Enables Auto Move Windows → soundbooth-dashboard.desktop:2 (backup path)
#   4) Redeploys + reloads the soundbooth-multiview-workspace Shell extension
#      (primary path — title-matches "Soundbooth Control", see its own header)
#   5) Binds Super+Page_Down / Super+Alt+2 workspace-2 keys

set -euo pipefail

DESKTOP_SRC="${HOME}/soundbooth-project/audio-routing/desktop/soundbooth-dashboard.desktop"
DESKTOP_DST="${HOME}/.local/share/applications/soundbooth-dashboard.desktop"
EXT_ID="auto-move-windows@gnome-shell-extensions.gcampax.github.com"
EXT_SCHEMA_DIR="${HOME}/.local/share/gnome-shell/extensions/${EXT_ID}/schemas"
APP_ENTRY="soundbooth-dashboard.desktop:2"

mkdir -p "${HOME}/.local/share/applications"
if [[ -f "$DESKTOP_SRC" ]]; then
    install -m 0644 "$DESKTOP_SRC" "$DESKTOP_DST"
    echo "Installed $DESKTOP_DST"
else
    echo "ERROR: missing $DESKTOP_SRC" >&2
    exit 1
fi

# Fixed workspaces (Auto Move needs a stable workspace index)
gsettings set org.gnome.mutter dynamic-workspaces false
gsettings set org.gnome.desktop.wm.preferences num-workspaces 2
echo "Workspaces: fixed count 2"

# Preferred: dedicated Shell extension (Mutter-native workspace move on Wayland)
LOCAL_EXT="soundbooth-multiview-workspace@soundbooth"
LOCAL_EXT_SRC="${HOME}/soundbooth-project/audio-routing/gnome-shell-extensions/${LOCAL_EXT}"
LOCAL_EXT_DST="${HOME}/.local/share/gnome-shell/extensions/${LOCAL_EXT}"
if [[ -d "$LOCAL_EXT_SRC" ]]; then
    mkdir -p "$LOCAL_EXT_DST"
    install -m 0644 "$LOCAL_EXT_SRC/metadata.json" "$LOCAL_EXT_DST/metadata.json"
    install -m 0644 "$LOCAL_EXT_SRC/extension.js" "$LOCAL_EXT_DST/extension.js"
    echo "Installed Shell extension $LOCAL_EXT (dashboard-repointed)"
fi
if [[ -d "$LOCAL_EXT_DST" ]]; then
    # disable+enable reloads the JS even if already enabled (picks up the retarget)
    gnome-extensions disable "$LOCAL_EXT" 2>/dev/null || true
    gnome-extensions enable "$LOCAL_EXT" 2>/dev/null && echo "Enabled/reloaded $LOCAL_EXT" \
        || echo "WARN: enable $LOCAL_EXT failed (may need: log out/in)" >&2
fi

# Optional backup: Auto Move Windows by desktop id
if gnome-extensions info "$EXT_ID" &>/dev/null; then
    gnome-extensions enable "$EXT_ID" 2>/dev/null || true
    if [[ -d "$EXT_SCHEMA_DIR" ]]; then
        current=$(gsettings --schemadir "$EXT_SCHEMA_DIR" get \
            org.gnome.shell.extensions.auto-move-windows application-list 2>/dev/null || echo "@as []")
        if echo "$current" | grep -q 'soundbooth-dashboard.desktop'; then
            echo "Auto Move already has soundbooth-dashboard rule"
        else
            python3 - <<PY
import subprocess, re, ast
cur = """${current}""".strip()
cur = re.sub(r'^@as\s*', '', cur)
try:
    lst = ast.literal_eval(cur) if cur else []
except Exception:
    lst = []
if not isinstance(lst, list):
    lst = []
lst = [x for x in lst if not str(x).startswith('soundbooth-multiview.desktop') and not str(x).startswith('soundbooth-dashboard.desktop')]
lst.append("${APP_ENTRY}")
val = "[" + ", ".join("'" + x.replace("'", "") + "'" for x in lst) + "]"
subprocess.check_call([
    "gsettings", "--schemadir", "${EXT_SCHEMA_DIR}",
    "set", "org.gnome.shell.extensions.auto-move-windows",
    "application-list", val,
])
print("Auto Move application-list =>", val)
PY
        fi
    fi
fi

# Make workspace 2 reachable (Ubuntu leaves switch-to-workspace-2 empty by default)
gsettings set org.gnome.desktop.wm.keybindings switch-to-workspace-2 "['<Super><Alt>2']"
gsettings set org.gnome.desktop.wm.keybindings move-to-workspace-2 "['<Super><Shift><Alt>2']"
echo "Keys: Super+Alt+2 -> workspace 2; Super+Page_Down -> next workspace"
echo "      Super+Shift+Page_Down -> move focused window to next workspace"

update-desktop-database "${HOME}/.local/share/applications" 2>/dev/null || true
echo "Done. Start the dashboard view via: ~/bin/start-booth-dashboard-view.sh"

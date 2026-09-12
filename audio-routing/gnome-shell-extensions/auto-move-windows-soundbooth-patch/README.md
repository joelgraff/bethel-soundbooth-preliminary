# Auto Move Windows — Soundbooth patch

GNOME Wayland ignores X11 `_NET_WM_DESKTOP` / `wmctrl` for real workspace moves.
This patch adds title/WM_CLASS matching for **Soundbooth Multiview** and moves it
to workspace index 1 (2nd workspace) via `MetaWindow.change_workspace_by_index`.

## Install (after GNOME updates reset the extension)

```bash
EXT=~/.local/share/gnome-shell/extensions/auto-move-windows@gnome-shell-extensions.gcampax.github.com
cp -a extension.js.orig "$EXT/extension.js.orig"   # keep backup
cp -a extension.js "$EXT/extension.js"
gnome-extensions disable auto-move-windows@gnome-shell-extensions.gcampax.github.com
gnome-extensions enable auto-move-windows@gnome-shell-extensions.gcampax.github.com
```

Or: `~/bin/configure-multiview-workspace.sh` (re-applies when extended).

## Undo

```bash
cp -a "$EXT/extension.js.orig" "$EXT/extension.js"
gnome-extensions disable auto-move-windows@…; gnome-extensions enable auto-move-windows@…
```

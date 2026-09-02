// SPDX-License-Identifier: MIT
// Move the Soundbooth Control dashboard window to workspace index 1 (2nd
// workspace) via MetaWindow.change_workspace_by_index — works on GNOME
// Wayland. X11 _NET_WM_DESKTOP / wmctrl / xdotool do NOT move Mutter
// workspaces.
//
// Originally built for "Soundbooth Multiview" (retired — its glanceable-
// preview role moved into the web control dashboard's own HDMI preview
// tiles). Repurposed in place rather than renamed: same UUID, same proven
// Wayland-native title-match mechanism, just a different title and a
// different window now. See dashboard/README.md.

import GLib from 'gi://GLib';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

// Vivaldi's --app= mode titles the window after the page's <title> — see
// dashboard/backend/static/index.html and start-booth-dashboard-view.sh.
const TITLE = 'Soundbooth Control';
const TARGET_WS = 1; // 0-based → GNOME workspace 2

export default class SoundboothDashboardWorkspace extends Extension {
    enable() {
        this._handler = global.display.connect('window-created', (_d, window) => {
            GLib.timeout_add(GLib.PRIORITY_DEFAULT, 500, () => {
                this._maybeMove(window);
                return GLib.SOURCE_REMOVE;
            });
        });
        // Re-scan periodically so late title/map still gets placed
        this._scanId = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, 3, () => {
            this._scanExisting();
            return GLib.SOURCE_CONTINUE;
        });
        this._scanExisting();
        log('soundbooth-dashboard-workspace: enabled (target workspace index ' + TARGET_WS + ')');
    }

    disable() {
        if (this._handler) {
            global.display.disconnect(this._handler);
            this._handler = null;
        }
        if (this._scanId) {
            GLib.source_remove(this._scanId);
            this._scanId = null;
        }
    }

    _ensureWorkspaces(minIndex) {
        const wm = global.workspace_manager;
        while (wm.n_workspaces <= minIndex)
            wm.append_new_workspace(false, global.get_current_time());
    }

    _maybeMove(window) {
        if (!window || window.skip_taskbar)
            return;

        let title = '';
        try {
            title = window.get_title() || '';
        } catch (_e) {
            return;
        }
        if (title.indexOf(TITLE) === -1)
            return;

        try {
            if (window.is_on_all_workspaces && window.is_on_all_workspaces())
                window.unstick();
        } catch (_e) { /* ignore */ }

        this._ensureWorkspaces(TARGET_WS);
        try {
            const ws = window.get_workspace();
            if (!ws || ws.index !== TARGET_WS) {
                window.change_workspace_by_index(TARGET_WS, false);
                log('soundbooth-dashboard-workspace: moved to workspace ' + (TARGET_WS + 1));
            }
        } catch (e) {
            log('soundbooth-dashboard-workspace: move failed: ' + e);
        }
    }

    _scanExisting() {
        const actors = global.get_window_actors();
        for (let i = 0; i < actors.length; i++)
            this._maybeMove(actors[i].meta_window);
    }
}

// SPDX-FileCopyrightText: 2011 Giovanni Campagna <gcampagna@src.gnome.org>
// SPDX-FileCopyrightText: 2011 Alessandro Crismani <alessandro.crismani@gmail.com>
// SPDX-FileCopyrightText: 2014 Florian Müllner <fmuellner@gnome.org>
//
// SPDX-License-Identifier: GPL-2.0-or-later
//
// SOUNDBooth patch: also move windows titled "Soundbooth Multiview" to workspace 2
// via MetaWindow.change_workspace_by_index (Wayland-native). X11 desktop hints fail
// under Mutter. Restore from extension.js.orig to undo.

import GLib from 'gi://GLib';
import Shell from 'gi://Shell';

import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

const SOUNDBOOTH_MULTIVIEW_TITLE = 'Soundbooth Multiview';
const SOUNDBOOTH_MULTIVIEW_WS = 1; // 0-based → workspace 2

class WindowMover {
    constructor(settings) {
        this._settings = settings;
        this._appSystem = Shell.AppSystem.get_default();
        this._appConfigs = new Map();
        this._appData = new Map();

        this._appSystem.connectObject('installed-changed',
            () => this._updateAppData(), this);

        this._settings.connectObject('changed',
            this._updateAppConfigs.bind(this), this);
        this._updateAppConfigs();

        // --- Soundbooth: title-based move (Mutter-native, works on Wayland) ---
        this._winCreatedId = global.display.connect('window-created', (_d, window) => {
            GLib.timeout_add(GLib.PRIORITY_DEFAULT, 600, () => {
                this._moveSoundboothMultiview(window);
                return GLib.SOURCE_REMOVE;
            });
        });
        this._scanId = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, 2, () => {
            this._scanSoundboothMultiview();
            return GLib.SOURCE_CONTINUE;
        });
        this._scanSoundboothMultiview();
    }

    _isSoundboothMultiview(window) {
        try {
            const title = window.get_title() || '';
            const wmClass = window.get_wm_class() || '';
            const wmInst = window.get_wm_class_instance() || '';
            // Broad match: this booth only uses GStreamer class for multiview ximagesink
            if (wmClass === 'GStreamer')
                return true;
            if (title.indexOf(SOUNDBOOTH_MULTIVIEW_TITLE) !== -1)
                return true;
            if (title.indexOf('Multiview') !== -1)
                return true;
            if (wmInst.indexOf('Multiview') !== -1 || wmInst.indexOf('Soundbooth') !== -1)
                return true;
            if (wmClass === 'Soundbooth Multiview')
                return true;
        } catch (_e) {
            return false;
        }
        return false;
    }

    _moveSoundboothMultiview(window) {
        if (!window || !this._isSoundboothMultiview(window))
            return;
        try {
            if (window.is_on_all_workspaces())
                window.unstick();
        } catch (_e) { /* ignore */ }
        try {
            const workspaceManager = global.workspace_manager;
            while (workspaceManager.n_workspaces <= SOUNDBOOTH_MULTIVIEW_WS)
                workspaceManager.append_new_workspace(false, global.get_current_time());
            const ws = window.get_workspace();
            if (!ws || ws.index !== SOUNDBOOTH_MULTIVIEW_WS) {
                // second arg must be false (same as stock Auto Move)
                window.change_workspace_by_index(SOUNDBOOTH_MULTIVIEW_WS, false);
                log('soundbooth: moved Multiview to workspace 2');
            }
        } catch (e) {
            log(`soundbooth multiview workspace move: ${e}`);
        }
    }

    _scanSoundboothMultiview() {
        const actors = global.get_window_actors();
        for (let i = 0; i < actors.length; i++)
            this._moveSoundboothMultiview(actors[i].meta_window);
    }

    _updateAppConfigs() {
        this._appConfigs.clear();

        this._settings.get_strv('application-list').forEach(v => {
            let [appId, num] = v.split(':');
            this._appConfigs.set(appId, parseInt(num) - 1);
        });

        this._updateAppData();
    }

    _updateAppData() {
        let ids = [...this._appConfigs.keys()];
        let removedApps = [...this._appData.keys()]
            .filter(a => !ids.includes(a.id));
        removedApps.forEach(app => {
            app.disconnectObject(this);
            this._appData.delete(app);
        });

        let addedApps = ids
            .map(id => this._appSystem.lookup_app(id))
            .filter(app => app && !this._appData.has(app));
        addedApps.forEach(app => {
            app.connectObject('windows-changed',
                this._appWindowsChanged.bind(this), this);
            this._appData.set(app, {windows: app.get_windows()});
        });
    }

    destroy() {
        if (this._winCreatedId) {
            global.display.disconnect(this._winCreatedId);
            this._winCreatedId = 0;
        }
        if (this._scanId) {
            GLib.source_remove(this._scanId);
            this._scanId = 0;
        }
        this._appSystem.disconnectObject(this);
        this._settings.disconnectObject(this);
        this._settings = null;

        this._appConfigs.clear();
        this._updateAppData();
    }

    _moveWindow(window, workspaceNum) {
        if (window.skip_taskbar || window.is_on_all_workspaces())
            return;

        // ensure we have the required number of workspaces
        let workspaceManager = global.workspace_manager;
        for (let i = workspaceManager.n_workspaces; i <= workspaceNum; i++) {
            window.change_workspace_by_index(i - 1, false);
            workspaceManager.append_new_workspace(false, 0);
        }

        window.change_workspace_by_index(workspaceNum, false);
    }

    _appWindowsChanged(app) {
        let data = this._appData.get(app);
        let windows = app.get_windows();

        // If get_compositor_private() returns non-NULL on a removed windows,
        // the window still exists and is just moved to a different workspace
        // or something; assume it'll be added back immediately, so keep it
        // to avoid moving it again
        windows.push(...data.windows.filter(w => {
            return !windows.includes(w) && w.get_compositor_private() !== null;
        }));

        let workspaceNum = this._appConfigs.get(app.id);
        windows.filter(w => !data.windows.includes(w)).forEach(window => {
            this._moveWindow(window, workspaceNum);
        });
        data.windows = windows;
    }
}

export default class AutoMoveExtension extends Extension {
    enable() {
        this._prevCheckWorkspaces = Main.wm._workspaceTracker._checkWorkspaces;
        Main.wm._workspaceTracker._checkWorkspaces =
            this._getCheckWorkspaceOverride(this._prevCheckWorkspaces);
        this._windowMover = new WindowMover(this.getSettings());
    }

    disable() {
        Main.wm._workspaceTracker._checkWorkspaces = this._prevCheckWorkspaces;
        this._windowMover.destroy();
        delete this._windowMover;
    }

    _getCheckWorkspaceOverride(originalMethod) {
        /* eslint-disable no-invalid-this */
        return function () {
            const keepAliveWorkspaces = [];
            let foundNonEmpty = false;
            for (let i = this._workspaces.length - 1; i >= 0; i--) {
                if (!foundNonEmpty) {
                    foundNonEmpty = this._workspaces[i].list_windows().some(
                        w => !w.is_on_all_workspaces());
                } else if (!this._workspaces[i]._keepAliveId) {
                    keepAliveWorkspaces.push(this._workspaces[i]);
                }
            }

            // make sure the original method only removes empty workspaces at the end
            keepAliveWorkspaces.forEach(ws => (ws._keepAliveId = 1));
            originalMethod.call(this);
            keepAliveWorkspaces.forEach(ws => delete ws._keepAliveId);

            return false;
        };
        /* eslint-enable no-invalid-this */
    }
}

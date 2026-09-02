#!/usr/bin/env python3
"""
Low-fps JPEG preview capture for the dashboard's HDMI output tiles — DP-2
(FreeShow Primary) and DP-3 (FreeShow Stage) only. DP-4 (program) is a
separate capture (see start-hdmi-preview-dp4.sh) since it reads the FFmpeg
UDP encode tee, not ScreenCast. DP-1 is not captured (see dashboard/README.md
for why — it's the booth's own screen, lowest value to preview remotely).

Reuses the exact org.gnome.Mutter.ScreenCast RecordMonitor technique already
proven in booth-multiview.py (same file's docstring explains why: x11grab is
black under Wayland, RecordWindow grabs the wrong surface for Electron/
FreeShow). This script is deliberately independent of booth-multiview.py —
separate ScreenCast sessions, no shared state — rather than hooking into its
internal compositor pipeline.

Each monitor gets its own pipewiresrc branch, overwriting a fixed file in
/dev/shm (tmpfs — no disk wear, cleared on reboot). Frame rate is throttled
with a plain wall-clock pad probe (drop buffers arriving too soon), not
GStreamer's `videorate` — videorate needs a couple of real timestamped
buffers before it will emit anything, which stalls the pipeline in PAUSED
(never reaching PLAYING) for many seconds against a mostly-static screen
(confirmed against the real booth: RecordMonitor's "is-recording" does not
mean "frames at a fixed rate regardless of content" the way it first reads —
an idle/static FreeShow output can go long stretches with no new buffer at
all). A probe has no such preroll requirement: it just drops what it doesn't
want, so the very first real frame still reaches the file immediately.

Run: ~/bin/hdmi-preview-capture.py   (installed via hdmi-preview.service)
Stop: Ctrl-C / systemctl --user stop hdmi-preview.service
"""
from __future__ import annotations

import glob
import os
import re
import signal
import subprocess
import sys
from pathlib import Path
from typing import Dict, Optional, Tuple

import dbus
from dbus.mainloop.glib import DBusGMainLoop

import gi

gi.require_version("Gst", "1.0")
from gi.repository import GLib, Gst  # noqa: E402

OUT_DIR = Path(os.environ.get("HDMI_PREVIEW_DIR", "/dev/shm/soundbooth-dashboard"))
TILE_W = int(os.environ.get("HDMI_PREVIEW_WIDTH", "640"))
TILE_H = int(os.environ.get("HDMI_PREVIEW_HEIGHT", "360"))
# Minimum seconds between written frames per monitor — a "glance" dashboard
# tile has no reason to burn CPU/GPU encoding faster than the UI polls.
MIN_INTERVAL_SEC = float(os.environ.get("HDMI_PREVIEW_MIN_INTERVAL_SEC", "2.0"))

TARGETS = {
    "primary": (
        os.environ.get("HDMI_PREVIEW_PRIMARY_CONNECTOR", "DP-2"),
        "dp2.jpg",
    ),
    "stage": (
        os.environ.get("HDMI_PREVIEW_STAGE_CONNECTOR", "DP-3"),
        "dp3.jpg",
    ),
}


def log(msg: str) -> None:
    print(msg, flush=True)


def ensure_display_env() -> None:
    # Same recipe as booth-multiview.py's ensure_display_env() — running as a
    # systemd --user service, not an interactive terminal, so DISPLAY/
    # XAUTHORITY/DBUS_SESSION_BUS_ADDRESS aren't inherited automatically.
    if not os.environ.get("DISPLAY"):
        os.environ["DISPLAY"] = ":0"
    if not os.environ.get("XAUTHORITY") or not os.path.isfile(
        os.environ.get("XAUTHORITY", "")
    ):
        runtime = os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")
        auths = sorted(glob.glob(f"{runtime}/.mutter-Xwaylandauth.*"), reverse=True)
        if auths:
            os.environ["XAUTHORITY"] = auths[0]
    if not os.environ.get("XDG_RUNTIME_DIR"):
        os.environ["XDG_RUNTIME_DIR"] = f"/run/user/{os.getuid()}"
    if not os.environ.get("DBUS_SESSION_BUS_ADDRESS"):
        os.environ["DBUS_SESSION_BUS_ADDRESS"] = (
            f"unix:path={os.environ['XDG_RUNTIME_DIR']}/bus"
        )


def pw_object_serial(node_id: int) -> Optional[str]:
    try:
        out = subprocess.check_output(
            ["pw-cli", "info", str(node_id)], text=True, stderr=subprocess.DEVNULL
        )
    except (subprocess.CalledProcessError, FileNotFoundError, OSError):
        return None
    for line in out.splitlines():
        s = line.strip()
        if "object.serial" in s and "=" in s:
            return s.split("=", 1)[1].strip().strip('"')
    return None


def connector_geom(connector: str) -> Optional[Tuple[int, int, int, int]]:
    try:
        out = subprocess.check_output(
            ["xrandr", "--query"], text=True, stderr=subprocess.DEVNULL, env=os.environ
        )
    except (subprocess.CalledProcessError, FileNotFoundError):
        return None
    for line in out.splitlines():
        if not line.startswith(connector + " ") or " connected" not in line:
            continue
        m = re.search(r"(\d+)x(\d+)\+(\d+)\+(\d+)", line)
        if m:
            return tuple(int(m.group(i)) for i in range(1, 5))  # type: ignore
    return None


class MutterScreenCast:
    """One independent ScreenCast session per monitor — see booth-multiview.py
    for why sessions must not be shared (Mutter delivers black/stale frames
    when multiple RecordMonitor streams share one session)."""

    def __init__(self) -> None:
        DBusGMainLoop(set_as_default=True)
        self.bus = dbus.SessionBus()
        self.node_ids: Dict[str, int] = {}
        self._sessions = []
        self._signal_matches = []

    def _on_pw(self, node_id, label: str = "") -> None:
        nid = int(node_id)
        if label in self.node_ids and self.node_ids[label] != nid:
            return
        self.node_ids[label] = nid
        log(f"  PipeWire {label} -> node {nid}")

    def start(self, targets: Dict[str, Tuple[str, str]]) -> None:
        sc = self.bus.get_object(
            "org.gnome.Mutter.ScreenCast", "/org/gnome/Mutter/ScreenCast"
        )
        iface = dbus.Interface(sc, "org.gnome.Mutter.ScreenCast")

        for label, (connector, _filename) in targets.items():
            if connector_geom(connector) is None:
                raise RuntimeError(f"connector {connector} not connected")

            session_path = iface.CreateSession(dbus.Dictionary({}, signature="sv"))
            session = self.bus.get_object("org.gnome.Mutter.ScreenCast", session_path)
            siface = dbus.Interface(session, "org.gnome.Mutter.ScreenCast.Session")
            stream_path = siface.RecordMonitor(
                connector,
                dbus.Dictionary(
                    {"cursor-mode": dbus.UInt32(0), "is-recording": dbus.Boolean(True)},
                    signature="sv",
                ),
            )
            match = self.bus.add_signal_receiver(
                lambda node_id, label=label: self._on_pw(node_id, label),
                signal_name="PipeWireStreamAdded",
                dbus_interface="org.gnome.Mutter.ScreenCast.Stream",
                path=str(stream_path),
            )
            self._signal_matches.append(match)
            siface.Start()
            self._sessions.append((label, siface))
            log(f"  session {label} <- RecordMonitor {connector} ({stream_path})")

        needed = tuple(targets.keys())
        deadline = GLib.get_monotonic_time() + 8_000_000
        while GLib.get_monotonic_time() < deadline:
            GLib.MainContext.default().iteration(may_block=False)
            if all(k in self.node_ids for k in needed):
                log(f"  preview monitors ready: {self.node_ids}")
                return
            GLib.usleep(50_000)
        missing = [k for k in needed if k not in self.node_ids]
        self.stop()
        raise RuntimeError(f"ScreenCast missing nodes: {missing}")

    def stop(self) -> None:
        for m in self._signal_matches:
            try:
                self.bus.remove_signal_receiver(m)
            except Exception:
                pass
        self._signal_matches.clear()
        for label, siface in self._sessions:
            try:
                siface.Stop()
            except Exception as e:
                log(f"ScreenCast stop {label}: {e}")
        self._sessions.clear()


def build_gst_desc(pw_bind: Dict[str, str], targets: Dict[str, Tuple[str, str]]) -> str:
    branches = []
    for label, (_connector, filename) in targets.items():
        bind = pw_bind[label]
        dest = OUT_DIR / filename
        branches.append(f"""
pipewiresrc name=pw_{label} {bind} always-copy=true do-timestamp=true !
  queue max-size-buffers=2 leaky=downstream !
  videoconvert ! videoscale !
  video/x-raw,width={TILE_W},height={TILE_H} !
  jpegenc name=jpegenc_{label} quality=70 !
  multifilesink location={dest}
""")
    return "\n".join(branches)


def main() -> int:
    ensure_display_env()
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    log("Starting HDMI preview capture (DP-2/DP-3 via Mutter ScreenCast)...")
    cast = MutterScreenCast()
    try:
        cast.start(TARGETS)
    except Exception as e:
        log(f"ERROR: ScreenCast failed: {e}")
        return 1

    Gst.init(None)
    pw_bind: Dict[str, str] = {}
    for label, nid in cast.node_ids.items():
        serial = pw_object_serial(nid)
        pw_bind[label] = f"target-object={serial}" if serial else f"path={nid}"

    desc = build_gst_desc(pw_bind, TARGETS)
    try:
        # Multiple disconnected pipewiresrc-to-multifilesink chains in one
        # description — parse_launch wraps them in a single Pipeline, same
        # pattern booth-multiview.py already uses for its own branches.
        pipeline = Gst.parse_launch(desc)
    except Exception as e:
        log(f"ERROR: pipeline parse: {e}")
        cast.stop()
        return 1

    # Wall-clock throttle: drop buffers arriving less than MIN_INTERVAL_SEC
    # after the last one we let through, per monitor. A pad probe (unlike
    # videorate) has no preroll semantics, so it never delays reaching
    # PLAYING — see the module docstring for why videorate was dropped.
    last_write_us: Dict[str, int] = {}

    def _throttle_probe(_pad, info, label):
        buf = info.get_buffer()
        if buf is None:
            return Gst.PadProbeReturn.OK
        now = GLib.get_monotonic_time()
        last = last_write_us.get(label, 0)
        if now - last < MIN_INTERVAL_SEC * 1_000_000:
            return Gst.PadProbeReturn.DROP
        last_write_us[label] = now
        return Gst.PadProbeReturn.OK

    for label in TARGETS:
        el = pipeline.get_by_name(f"jpegenc_{label}")
        if el is None:
            log(f"WARNING: jpegenc_{label} not found, no throttle attached")
            continue
        sinkpad = el.get_static_pad("sink")
        sinkpad.add_probe(
            Gst.PadProbeType.BUFFER, _throttle_probe, label
        )

    loop = GLib.MainLoop()
    state = {"stopping": False}

    def shutdown(*_a) -> None:
        if state["stopping"]:
            return
        state["stopping"] = True
        log("Stopping...")
        try:
            pipeline.set_state(Gst.State.NULL)
        except Exception:
            pass
        cast.stop()
        if loop.is_running():
            loop.quit()

    signal.signal(signal.SIGINT, shutdown)
    signal.signal(signal.SIGTERM, shutdown)

    bus = pipeline.get_bus()
    bus.add_signal_watch()

    def on_msg(_bus, msg):
        if msg.type == Gst.MessageType.ERROR:
            err, dbg = msg.parse_error()
            log(f"GST ERROR: {err}")
            if dbg:
                log(f"  {dbg}")
            shutdown()
        elif msg.type == Gst.MessageType.EOS:
            log("GST EOS")
            shutdown()
        return True

    bus.connect("message", on_msg)

    if pipeline.set_state(Gst.State.PLAYING) == Gst.StateChangeReturn.FAILURE:
        log("ERROR: failed to set pipeline PLAYING")
        shutdown()
        return 1

    log(f"Capturing to {OUT_DIR} at >={MIN_INTERVAL_SEC}s interval, {TILE_W}x{TILE_H}")
    loop.run()
    return 0


if __name__ == "__main__":
    sys.exit(main())

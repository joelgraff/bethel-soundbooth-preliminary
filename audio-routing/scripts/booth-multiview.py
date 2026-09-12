#!/usr/bin/env python3
"""
Booth multiview for GNOME Wayland (Mutter).

Problem: ffmpeg x11grab of monitor regions is pure black under Wayland.
Fix: org.gnome.Mutter.ScreenCast **RecordMonitor** per connector:

  - DP-2 FreeShow Primary/FOH (RecordMonitor)
  - DP-3 FreeShow Stage (RecordMonitor)
  - Program + encode tiles: FFmpeg UDP :5001 → appsrc tee
    (DP-4 ScreenCast of ffplay was damage-starved / frozen until workspace switch)

Do **not** use RecordWindow for FreeShow: Electron/Xwayland window-id capture
often returns the wrong surface (e.g. booth terminal) instead of the output.

2×2 grid on booth ultrawide (DP-1) via GStreamer compositor + ximagesink.

  1 Primary/FOH | 2 Stage
  3 Program     | 4 Encode/SRT   (3+4 share encode live)

Usage:
  ~/bin/booth-multiview.py
  ~/bin/start-booth-multiview.sh

Stop: Ctrl-C  or  kill $(cat $XDG_RUNTIME_DIR/soundbooth-multiview/multiview.pid)
"""
from __future__ import annotations

import argparse
import glob
import os
import re
import signal
import subprocess
import sys
import threading
import time
from typing import Dict, Optional, Tuple

import dbus
from dbus.mainloop.glib import DBusGMainLoop

import gi

gi.require_version("Gst", "1.0")
from gi.repository import GLib, Gst  # noqa: E402


def log(msg: str) -> None:
    print(msg, flush=True)


def ensure_display_env() -> None:
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
    """Resolve PipeWire object.serial for gst pipewiresrc target-object=."""
    try:
        out = subprocess.check_output(
            ["pw-cli", "info", str(node_id)],
            text=True,
            stderr=subprocess.DEVNULL,
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
    """
    One independent ScreenCast *session* per monitor.

    Mutter often delivers black/stale frames for DP-2/DP-3 when multiple
    RecordMonitor streams share a single session; separate sessions work.
    """

    def __init__(self) -> None:
        DBusGMainLoop(set_as_default=True)
        self.bus = dbus.SessionBus()
        self.node_ids: Dict[str, int] = {}
        self._sessions = []  # list of (label, siface)
        self._signal_matches = []

    def _on_pw(self, node_id, label: str = "") -> None:
        nid = int(node_id)
        if label in self.node_ids and self.node_ids[label] != nid:
            log(f"  ignore late PW signal {label}: {nid} (have {self.node_ids[label]})")
            return
        self.node_ids[label] = nid
        log(f"  PipeWire {label} → node {nid}")

    def start(
        self,
        primary_connector: str,
        stage_connector: str,
        program_connector: str = "",
    ) -> None:
        """ScreenCast FreeShow outputs only (Primary + Stage).

        ``program_connector`` is accepted for API stability but ignored: DP-4
        program is shown via encode tee (ScreenCast of ffplay was unreliable).
        """
        del program_connector  # program tile uses encode, not RecordMonitor
        sc = self.bus.get_object(
            "org.gnome.Mutter.ScreenCast", "/org/gnome/Mutter/ScreenCast"
        )
        iface = dbus.Interface(sc, "org.gnome.Mutter.ScreenCast")

        for label, connector in (
            ("primary", primary_connector),
            ("stage", stage_connector),
        ):
            if connector_geom(connector) is None:
                raise RuntimeError(f"connector {connector} not connected")

            session_path = iface.CreateSession(dbus.Dictionary({}, signature="sv"))
            session = self.bus.get_object(
                "org.gnome.Mutter.ScreenCast", session_path
            )
            siface = dbus.Interface(
                session, "org.gnome.Mutter.ScreenCast.Session"
            )
            # is-recording=true: continuous frames (not damage-only).
            stream_path = siface.RecordMonitor(
                connector,
                dbus.Dictionary(
                    {
                        "cursor-mode": dbus.UInt32(0),
                        "is-recording": dbus.Boolean(True),
                    },
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
            log(f"  session {label} ← RecordMonitor {connector} ({stream_path})")

        needed = ("primary", "stage")
        deadline = time.time() + 8.0
        while time.time() < deadline:
            GLib.MainContext.default().iteration(may_block=False)
            if all(k in self.node_ids for k in needed):
                ids = [self.node_ids[k] for k in needed]
                if len(set(ids)) < len(needed):
                    log(f"  WARNING: non-unique PW nodes {self.node_ids}")
                else:
                    log(f"  FreeShow monitors ready: {self.node_ids}")
                return
            time.sleep(0.05)
        missing = [k for k in needed if k not in self.node_ids]
        self.stop()
        raise RuntimeError(f"ScreenCast missing nodes: {missing}")

    def pump(self) -> None:
        GLib.MainContext.default().iteration(may_block=False)

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


def build_gst_desc(
    nodes: Dict[str, str], tile_w: int, tile_h: int, fps: int
) -> str:
    """Compositor grid; encode appsrc tees to tiles 3+4.

    ``nodes`` values are pipewiresrc bind props for FreeShow monitors only
    (``target-object=…`` / ``path=…``). Program (DP-4) is **not** ScreenCast:
    Mutter RecordMonitor of ffplay/Xwayland was damage-starved (~0–2 fps) and
    only refreshed on workspace switch; UDP encode stays live. Tile 3+4 both
    show the encode/SRT picture (same ATEM program).

    ScreenCast (Primary/Stage):
    - is-recording on RecordMonitor for continuous frames
    - always-copy=true, max-lateness=-1, qos=false, running-time PTS probes
    """
    # note: textoverlay needs pango plugin (gstreamer1.0-x provides it)
    return f"""
compositor name=comp background=black
  sink_0::xpos=0 sink_0::ypos=0 sink_0::max-lateness=-1 sink_0::qos=false
  sink_1::xpos={tile_w} sink_1::ypos=0 sink_1::max-lateness=-1 sink_1::qos=false
  sink_2::xpos=0 sink_2::ypos={tile_h} sink_2::max-lateness=-1 sink_2::qos=false
  sink_3::xpos={tile_w} sink_3::ypos={tile_h} sink_3::max-lateness=-1 sink_3::qos=false !
videoconvert !
video/x-raw,width={tile_w * 2},height={tile_h * 2} !
ximagesink name=sink force-aspect-ratio=true sync=false

pipewiresrc name=pw_primary {nodes['primary']} always-copy=true do-timestamp=true !
  queue max-size-buffers=2 leaky=downstream !
  videoconvert ! videoscale ! video/x-raw,width={tile_w},height={tile_h} !
  textoverlay text="1 Primary/FOH DP-2" valignment=top halignment=left
    font-desc="Sans Bold 16" shaded-background=true !
  comp.sink_0

pipewiresrc name=pw_stage {nodes['stage']} always-copy=true do-timestamp=true !
  queue max-size-buffers=2 leaky=downstream !
  videoconvert ! videoscale ! video/x-raw,width={tile_w},height={tile_h} !
  textoverlay text="2 Stage DP-3" valignment=top halignment=left
    font-desc="Sans Bold 16" shaded-background=true !
  comp.sink_1

appsrc name=encsrc is-live=true format=time do-timestamp=false block=false
  caps=video/x-raw,format=BGR,width={tile_w},height={tile_h},framerate={fps}/1 !
  tee name=enc_tee allow-not-linked=true

enc_tee. ! queue max-size-buffers=2 leaky=downstream !
  videoconvert ! videoscale ! video/x-raw,width={tile_w},height={tile_h} !
  textoverlay text="3 Program (encode live)" valignment=top halignment=left
    font-desc="Sans Bold 16" shaded-background=true !
  comp.sink_2

enc_tee. ! queue max-size-buffers=2 leaky=downstream !
  videoconvert ! videoscale ! video/x-raw,width={tile_w},height={tile_h} !
  textoverlay text="4 FFmpeg encode / SRT" valignment=top halignment=left
    font-desc="Sans Bold 16" shaded-background=true !
  comp.sink_3
"""


def ensure_gnome_workspaces(min_count: int = 2) -> None:
    """Fixed workspaces so multiview can land on workspace 2."""
    try:
        subprocess.run(
            [
                "gsettings",
                "set",
                "org.gnome.mutter",
                "dynamic-workspaces",
                "false",
            ],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        cur = subprocess.check_output(
            [
                "gsettings",
                "get",
                "org.gnome.desktop.wm.preferences",
                "num-workspaces",
            ],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
        n = int(cur) if cur.isdigit() else 1
        if n < min_count:
            subprocess.run(
                [
                    "gsettings",
                    "set",
                    "org.gnome.desktop.wm.preferences",
                    "num-workspaces",
                    str(min_count),
                ],
                check=False,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            log(f"GNOME workspaces set to {min_count} (was {n})")
    except Exception as e:
        log(f"workspace ensure note: {e}")


def move_window_to_workspace(wid: str, workspace_1based: int) -> None:
    """
    Best-effort workspace move.

    On GNOME Wayland, X11 _NET_WM_DESKTOP is often ignored by Mutter. Preferred
    path is Auto Move Windows (native) via soundbooth-multiview.desktop.
    Fallback: Super+Shift+End (move to last workspace) after focus.
    """
    idx = max(0, workspace_1based - 1)
    # Still set X11 hints (helps some tools / Xwayland edge cases)
    try:
        subprocess.run(
            [
                "xprop",
                "-id",
                wid,
                "-f",
                "_NET_WM_DESKTOP",
                "32c",
                "-set",
                "_NET_WM_DESKTOP",
                str(idx),
            ],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except Exception:
        pass
    try:
        subprocess.run(
            ["wmctrl", "-i", "-r", wid, "-t", str(idx)],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except FileNotFoundError:
        pass
    # Do NOT fake Super+… keys via X11 — they do not reach Mutter on Wayland
    # and spam "_NET_ACTIVE_WINDOW timestamp 0". Workspace move is handled by the
    # patched Auto Move Windows extension (MetaWindow.change_workspace_by_index).


def find_multiview_window_ids() -> list:
    try:
        tree = subprocess.check_output(
            ["xwininfo", "-root", "-tree"], text=True, stderr=subprocess.DEVNULL
        )
    except Exception:
        return []
    candidates = []
    for line in tree.splitlines():
        if (
            "Soundbooth Multiview" in line
            or "GStreamer" in line
            or "ximagesink" in line.lower()
        ):
            m = re.match(r"\s*(0x[0-9a-fA-F]+)", line)
            if m:
                candidates.append(m.group(1))
    # de-dupe preserve order
    seen = set()
    out = []
    for w in candidates:
        if w not in seen:
            seen.add(w)
            out.append(w)
    return out


def move_ximagesink_window(
    win_x: int,
    win_y: int,
    w: int,
    h: int,
    workspace_1based: int = 2,
) -> None:
    """Title, geometry, and GNOME workspace for multiview (never raise)."""
    for wid in find_multiview_window_ids()[:6]:
        try:
            subprocess.run(
                [
                    "xprop",
                    "-id",
                    wid,
                    "-f",
                    "WM_NAME",
                    "8s",
                    "-set",
                    "WM_NAME",
                    "Soundbooth Multiview",
                ],
                check=False,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            subprocess.run(
                [
                    "xprop",
                    "-id",
                    wid,
                    "-f",
                    "_NET_WM_NAME",
                    "8u",
                    "-set",
                    "_NET_WM_NAME",
                    "Soundbooth Multiview",
                ],
                check=False,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        except Exception:
            pass
        if workspace_1based > 0:
            move_window_to_workspace(wid, workspace_1based)
        for cmd in (
            ["xdotool", "windowmove", wid, str(win_x), str(win_y)],
            ["xdotool", "windowsize", wid, str(w), str(h)],
            ["wmctrl", "-i", "-r", wid, "-e", f"0,{win_x},{win_y},{w},{h}"],
        ):
            try:
                subprocess.run(
                    cmd,
                    check=False,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
            except FileNotFoundError:
                continue


def main() -> int:
    ensure_display_env()

    # GNOME Shell Auto Move Windows matches StartupWMClass=GStreamer (ximagesink).
    # Window title is set separately for the operator.
    try:
        GLib.set_prgname("soundbooth-multiview")
        GLib.set_application_name("Soundbooth Multiview")
    except Exception:
        pass

    ap = argparse.ArgumentParser(description="Soundbooth multiview (Wayland-safe)")
    ap.add_argument("--fps", type=int, default=int(os.environ.get("MULTIVIEW_FPS", "8")))
    ap.add_argument("--tile-w", type=int, default=960)
    ap.add_argument("--tile-h", type=int, default=540)
    ap.add_argument(
        "--encode-url",
        default=os.environ.get("MULTIVIEW_ENCODE_URL", "udp://127.0.0.1:5001"),
    )
    ap.add_argument(
        "--booth",
        default=os.environ.get("MULTIVIEW_BOOTH_CONNECTOR", "DP-1"),
    )
    ap.add_argument(
        "--program-connector",
        default=os.environ.get("MULTIVIEW_PROGRAM_CONNECTOR", "DP-4"),
    )
    ap.add_argument(
        "--workspace",
        type=int,
        default=int(os.environ.get("MULTIVIEW_WORKSPACE", "2")),
        help="GNOME workspace number (1-based) for multiview window; 0=current",
    )
    args = ap.parse_args()

    rundir = os.path.join(
        os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}"),
        "soundbooth-multiview",
    )
    os.makedirs(rundir, exist_ok=True)
    pidfile = os.path.join(rundir, "multiview.pid")
    with open(pidfile, "w") as f:
        f.write(str(os.getpid()))

    booth = connector_geom(args.booth)
    if not booth:
        log(f"ERROR: booth connector {args.booth} not found")
        return 1
    bw, bh, bx, by = booth
    out_w, out_h = args.tile_w * 2, args.tile_h * 2
    win_x = bx + max(0, (bw - out_w) // 2)
    win_y = by + max(0, (bh - out_h) // 2)

    if args.workspace > 0:
        ensure_gnome_workspaces(max(2, args.workspace))
        log(f"Multiview target: GNOME workspace {args.workspace} on {args.booth}")

    primary_conn = os.environ.get("MULTIVIEW_PRIMARY_CONNECTOR", "DP-2")
    stage_conn = os.environ.get("MULTIVIEW_STAGE_CONNECTOR", "DP-3")
    for label, conn in (
        ("Primary/FOH", primary_conn),
        ("Stage", stage_conn),
        ("Program", args.program_connector),
    ):
        g = connector_geom(conn)
        if not g:
            log(f"ERROR: {label} connector {conn} not connected")
            return 1
        log(f"  {label}: {conn} {g[0]}x{g[1]}+{g[2]}+{g[3]}")

    log("Starting Mutter ScreenCast (FreeShow DP-2/DP-3; program via encode)…")
    cast = MutterScreenCast()
    try:
        cast.start(primary_conn, stage_conn, args.program_connector)
    except Exception as e:
        log(f"ERROR: ScreenCast failed: {e}")
        return 1

    Gst.init(None)
    # Prefer target-object=serial (GStreamer path=node-id often "target not found")
    pw_bind: Dict[str, str] = {}
    for label, nid in cast.node_ids.items():
        serial = pw_object_serial(nid)
        if serial:
            pw_bind[label] = f"target-object={serial}"
            log(f"  pipewiresrc {label}: node {nid} serial {serial}")
        else:
            pw_bind[label] = f"path={nid}"
            log(f"  pipewiresrc {label}: node {nid} (path fallback, no serial)")
    log("  program+encode tiles: shared UDP :5001 feeder (not DP-4 ScreenCast)")
    desc = build_gst_desc(pw_bind, args.tile_w, args.tile_h, args.fps)
    log(
        f"Pipeline {out_w}x{out_h} @{args.fps}fps on {args.booth} "
        f"(target +{win_x}+{win_y})"
    )
    try:
        pipeline = Gst.parse_launch(desc)
    except Exception as e:
        log(f"ERROR: pipeline parse: {e}")
        cast.stop()
        return 1

    encsrc = pipeline.get_by_name("encsrc")
    frame_bytes = args.tile_w * args.tile_h * 3
    # Mid-stream UDP/H.264 join needs large probe + discardcorrupt; "nobuffer"
    # alone fails with endless "non-existing PPS" and produces a black tile.
    encode_in = args.encode_url
    if "udp://" in encode_in and "?" not in encode_in:
        # timeout=0: wait forever for mid-stream join (default 10s exited feeder
        # when multiview autostart beat ffmpeg-capture ready).
        encode_in = (
            encode_in + "?fifo_size=5000000&overrun_nonfatal=1&timeout=0"
        )
    ff_err_path = os.path.join(rundir, "encode-feeder.err")
    ff_cmd = [
        "ffmpeg",
        "-hide_banner",
        "-loglevel",
        "warning",
        "-fflags",
        "+genpts+discardcorrupt",
        "-analyzeduration",
        "5000000",
        "-probesize",
        "5000000",
        "-i",
        encode_in,
        "-an",
        "-vf",
        f"scale={args.tile_w}:{args.tile_h}:force_original_aspect_ratio=decrease,"
        f"pad={args.tile_w}:{args.tile_h}:(ow-iw)/2:(oh-ih)/2",
        "-r",
        str(args.fps),
        "-f",
        "rawvideo",
        "-pix_fmt",
        "bgr24",
        "pipe:1",
    ]
    log(f"Encode feeder: mid-stream safe UDP decode ({encode_in})")

    def _spawn_feeder() -> subprocess.Popen:
        # File stderr (not PIPE): unread PIPE fills and deadlocks ffmpeg.
        err_f = open(ff_err_path, "ab", buffering=0)
        return subprocess.Popen(
            ff_cmd,
            stdout=subprocess.PIPE,
            stderr=err_f,
            bufsize=frame_bytes * 8,
        )

    ff_holder: list = [_spawn_feeder()]
    stop_flag = threading.Event()

    def _running_pts() -> int:
        """Pipeline running time so compositor does not drop pads as late."""
        clock = pipeline.get_clock()
        if clock is None:
            return Gst.CLOCK_TIME_NONE
        now = clock.get_time()
        base = pipeline.get_base_time()
        if now == Gst.CLOCK_TIME_NONE or now < base:
            return Gst.CLOCK_TIME_NONE
        return int(now - base)

    # ScreenCast pad probes: align PTS with encode + count frames (stall detect).
    # Without this, pipewiresrc times can lag the appsrc clock and compositor
    # keeps the last Program/Primary/Stage buffer until a workspace redraw.
    sc_frame_counts: Dict[str, int] = {
        "pw_primary": 0,
        "pw_stage": 0,
    }

    def _attach_screencast_pts_probe(el_name: str) -> None:
        el = pipeline.get_by_name(el_name)
        if el is None:
            log(f"WARNING: pipeline missing {el_name}")
            return
        srcpad = el.get_static_pad("src")
        if srcpad is None:
            log(f"WARNING: {el_name} has no src pad")
            return

        def _probe(_pad, info, name=el_name):
            buf = info.get_buffer()
            if buf is None:
                return Gst.PadProbeReturn.OK
            # Count first — make_writable can fail on DMA-BUF and hid real rates.
            sc_frame_counts[name] = sc_frame_counts.get(name, 0) + 1
            try:
                wbuf = buf.make_writable()
            except Exception:
                return Gst.PadProbeReturn.OK
            pts = _running_pts()
            if pts != Gst.CLOCK_TIME_NONE:
                wbuf.pts = pts
                wbuf.dts = Gst.CLOCK_TIME_NONE
            return Gst.PadProbeReturn.OK

        srcpad.add_probe(
            Gst.PadProbeType.BUFFER | Gst.PadProbeType.BUFFER_LIST, _probe
        )
        log(f"  ScreenCast PTS probe on {el_name}")

    for _pw in ("pw_primary", "pw_stage"):
        _attach_screencast_pts_probe(_pw)

    def feed_encode() -> None:
        """Push decoded encode frames into appsrc; restart ffmpeg if it dies."""
        duration = int(Gst.SECOND / max(args.fps, 1))
        frames = 0
        while not stop_flag.is_set():
            proc = ff_holder[0]
            if proc.poll() is not None:
                err_tail = ""
                try:
                    with open(ff_err_path, "rb") as ef:
                        ef.seek(0, os.SEEK_END)
                        sz = ef.tell()
                        ef.seek(max(0, sz - 400))
                        err_tail = ef.read().decode("utf-8", errors="replace").strip()
                except OSError:
                    pass
                log(
                    f"Encode feeder exited code={proc.returncode}; restarting…"
                    + (f" err={err_tail[-200:]}" if err_tail else "")
                )
                time.sleep(1.0)
                if stop_flag.is_set():
                    break
                ff_holder[0] = _spawn_feeder()
                continue
            assert proc.stdout is not None
            data = proc.stdout.read(frame_bytes)
            if not data or len(data) < frame_bytes:
                time.sleep(0.05)
                continue
            buf = Gst.Buffer.new_allocate(None, frame_bytes, None)
            buf.fill(0, data)
            # Live ScreenCast pads use real clock time; synthetic pts=0..n made
            # every encode buffer "late" → black tile 4 while feeder still ran.
            buf.pts = _running_pts()
            buf.duration = duration
            ret = encsrc.emit("push-buffer", buf)
            frames += 1
            if frames == 1 or frames % max(args.fps * 30, 1) == 0:
                # Spot-check luma so black-decode is visible in the log
                step = max(1, frame_bytes // 3000)
                sample = data[0:frame_bytes:step]
                avg = (sum(sample) / len(sample)) if sample else 0.0
                log(
                    f"Encode feeder frames={frames} push={ret} "
                    f"sample_avg={avg:.1f}"
                )
            if ret != Gst.FlowReturn.OK:
                # Transient appsrc backpressure — keep feeding
                time.sleep(0.02)
        try:
            p = ff_holder[0]
            if p.poll() is None:
                p.kill()
        except Exception:
            pass

    feeder = threading.Thread(target=feed_encode, daemon=True)

    loop = GLib.MainLoop()
    state = {"stopping": False}

    def shutdown(*_a) -> None:
        if state["stopping"]:
            return
        state["stopping"] = True
        log("Stopping…")
        stop_flag.set()
        try:
            pipeline.set_state(Gst.State.NULL)
        except Exception:
            pass
        try:
            if ff_holder[0].poll() is None:
                ff_holder[0].kill()
        except Exception:
            pass
        cast.stop()
        try:
            os.remove(pidfile)
        except OSError:
            pass
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

    feeder.start()
    ws = args.workspace

    def place(_=None):
        # Unmaximize first (maximized Xwayland windows confuse workspace placement)
        for wid in find_multiview_window_ids()[:4]:
            try:
                subprocess.run(
                    [
                        "wmctrl",
                        "-i",
                        "-r",
                        wid,
                        "-b",
                        "remove,maximized_vert,maximized_horz",
                    ],
                    check=False,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
            except FileNotFoundError:
                pass
        move_ximagesink_window(win_x, win_y, out_w, out_h, workspace_1based=ws)
        return False

    GLib.timeout_add(800, place)
    GLib.timeout_add(2000, place)
    GLib.timeout_add(4500, place)
    GLib.timeout_add(8000, place)
    GLib.timeout_add(100, lambda: (cast.pump(), True)[1])

    sc_last = {"t": time.time(), "c": dict(sc_frame_counts)}

    def log_screencast_rates(_=None):
        """Warn if a ScreenCast tile stops receiving frames (frozen preview)."""
        now = time.time()
        dt = max(now - sc_last["t"], 0.001)
        parts = []
        stalled = []
        for name in ("pw_primary", "pw_stage"):
            cur = sc_frame_counts.get(name, 0)
            prev = sc_last["c"].get(name, 0)
            rate = (cur - prev) / dt
            short = name.replace("pw_", "")
            parts.append(f"{short}={rate:.1f}/s")
            if rate < 0.5:
                stalled.append(short)
        sc_last["t"] = now
        sc_last["c"] = dict(sc_frame_counts)
        msg = "ScreenCast rates: " + " ".join(parts)
        if stalled:
            log(msg + f"  STALL={','.join(stalled)} (tile may look frozen)")
        else:
            log(msg)
        return True

    GLib.timeout_add_seconds(15, log_screencast_rates)

    log(
        f"Multiview running (ScreenCast + encode)"
        f"{f'; target GNOME workspace {ws} via Auto Move + StartupWMClass' if ws > 0 else ''}"
        f". Ctrl-C to stop."
    )
    log("Switch workspaces: Super+Page_Down / Super+Alt+2  (empty ws2? multiview should be there)")
    try:
        loop.run()
    except KeyboardInterrupt:
        shutdown()
    finally:
        stop_flag.set()
        try:
            pipeline.set_state(Gst.State.NULL)
        except Exception:
            pass
        cast.stop()
        try:
            if ff_holder[0].poll() is None:
                ff_holder[0].kill()
        except Exception:
            pass
        try:
            os.remove(pidfile)
        except OSError:
            pass
    return 0


if __name__ == "__main__":
    sys.exit(main())

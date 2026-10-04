#!/usr/bin/env python3
"""Tests for app/ptz.py against a fake VISCA-over-TCP camera (never the real one).

Run from dashboard/backend:  .venv/bin/python tests/ptz-visca-test.py
Exit 0 = all passed.
"""
from __future__ import annotations

import os
import socketserver
import sys
import tempfile
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app import ptz  # noqa: E402


class FakeCamera:
    def __init__(self):
        self.power = 0x02
        self.frames: list[bytes] = []
        self.fail_next = False
        outer = self

        class Handler(socketserver.BaseRequestHandler):
            def handle(self):
                data = self.request.recv(64)
                if not data:
                    return
                outer.frames.append(data)
                if outer.fail_next:
                    outer.fail_next = False
                    self.request.sendall(bytes([0x90, 0x60, 0x02, 0xFF]))
                    return
                if data[1] == 0x09:  # inquiry
                    q = data[2:4]
                    if q == b"\x04\x00":
                        self.request.sendall(bytes([0x90, 0x50, outer.power, 0xFF]))
                    elif q == b"\x06\x12":  # pan 0x0010, tilt -0x0010 (0xFFF0)
                        self.request.sendall(bytes([0x90, 0x50, 0, 0, 0x01, 0, 0x0F, 0x0F, 0x0F, 0, 0xFF]))
                    elif q == b"\x04\x47":  # zoom 0x1234
                        self.request.sendall(bytes([0x90, 0x50, 1, 2, 3, 4, 0xFF]))
                else:
                    self.request.sendall(bytes([0x90, 0x41, 0xFF, 0x90, 0x51, 0xFF]))

        class Server(socketserver.ThreadingTCPServer):
            allow_reuse_address = True
            daemon_threads = True

        self.server = Server(("127.0.0.1", 0), Handler)
        self.port = self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def commands(self):
        return [f for f in self.frames if f[1] != 0x09]

    def close(self):
        self.server.shutdown()
        self.server.server_close()


FAILED = 0


def check(label, cond):
    global FAILED
    print(("  ok   - " if cond else "  FAIL - ") + label)
    if not cond:
        FAILED += 1


def raises(label, exc, fn, *a, **k):
    try:
        fn(*a, **k)
    except exc:
        check(label, True)
    except Exception as e:  # wrong exception type
        check(f"{label} (got {type(e).__name__}: {e})", False)
    else:
        check(f"{label} (nothing raised)", False)


tmp = tempfile.mkdtemp()
os.environ["PTZ_PRESETS_FILE"] = str(Path(tmp) / "presets.json")
os.environ["PTZ_CAMERA_IP"] = "127.0.0.1"
cam = FakeCamera()
ptz.VISCA_PORT = cam.port
ptz.DRIVE_WATCHDOG_SEC = 0.3

# --- status
st = ptz.get_status()
check("status reachable/on", st["reachable"] and st["power"] == "on")
check("pan decoded", st["pan"] == 0x10)
check("tilt decoded negative", st["tilt"] == -0x10)
check("zoom decoded", st["zoom"] == 0x1234)
cam.power = 0x03
st = ptz.get_status()
check("standby reported, no position queried", st["power"] == "standby" and "pan" not in st)

# --- standby refuses commands and sends none
cam.frames.clear()
raises("move refused in standby", ptz.PtzStandbyError, ptz.move, "left")
raises("home refused in standby", ptz.PtzStandbyError, ptz.home)
raises("zoom refused in standby", ptz.PtzStandbyError, ptz.zoom, "in")
check("no drive frame sent in standby", cam.commands() == [])
ptz.move("stop")  # a stop must always go through
check("stop sent even in standby", cam.commands() == [bytes([0x81, 1, 6, 1, 8, 8, 3, 3, 0xFF])])

# --- driving
cam.power = 0x02
cam.frames.clear()
ptz.move("upleft", 5)
check("upleft frame", cam.commands()[-1] == bytes([0x81, 1, 6, 1, 5, 5, 0x01, 0x01, 0xFF]))
ptz.move("right", 99)
check("speed clamped (pan 0x18 / tilt 0x14)", cam.commands()[-1] == bytes([0x81, 1, 6, 1, 0x18, 0x14, 0x02, 0x03, 0xFF]))
raises("unknown direction", ptz.PtzError, ptz.move, "sideways")
cam.frames.clear()
time.sleep(0.8)
cmds = cam.commands()
check("watchdog stopped pan/tilt and zoom", bytes([0x81, 1, 6, 1, 1, 1, 3, 3, 0xFF]) in cmds
      and bytes([0x81, 1, 4, 7, 0, 0xFF]) in cmds)
cam.frames.clear()
ptz.move("left", 4)
ptz.move("stop")
time.sleep(0.6)
check("explicit stop disarms the watchdog (no extra stop)", len(cam.commands()) == 2)
ptz.zoom("in", 3)
check("zoom in frame", cam.commands()[-1] == bytes([0x81, 1, 4, 7, 0x23, 0xFF]))
ptz.zoom("out", 2)
check("zoom out frame", cam.commands()[-1] == bytes([0x81, 1, 4, 7, 0x32, 0xFF]))
ptz.zoom("stop")
ptz.home()
check("home frame", cam.commands()[-1] == bytes([0x81, 1, 6, 4, 0xFF]))

# --- presets
check("no presets initially", ptz.load_presets() == [])
raises("recall of unnamed slot refused", ptz.PtzError, ptz.recall_preset, 3)
ptz.save_preset("Pulpit", 3, save_position=True)
check("save sends set-preset frame", cam.commands()[-1] == bytes([0x81, 1, 4, 0x3F, 0x01, 3, 0xFF]))
ptz.save_preset("Choir", 1, save_position=False)
check("rename-only does not touch the camera", cam.commands()[-1] == bytes([0x81, 1, 4, 0x3F, 0x01, 3, 0xFF]))
check("presets sorted by slot", [p["slot"] for p in ptz.load_presets()] == [1, 3])
ptz.recall_preset(3)
check("recall frame", cam.commands()[-1] == bytes([0x81, 1, 4, 0x3F, 0x02, 3, 0xFF]))
raises("overwriting a named slot needs confirmation", ptz.PtzError,
       ptz.save_preset, "Pulpit 2", 3, save_position=True)
ptz.save_preset("Pulpit 2", 3, save_position=True, overwrite=True)
check("overwrite allowed when confirmed", any(p["name"] == "Pulpit 2" for p in ptz.load_presets()))
raises("duplicate name (case-insensitive) refused", ptz.PtzError,
       ptz.save_preset, "choir", 9, save_position=False)
raises("empty name refused", ptz.PtzError, ptz.save_preset, "  ", 9, save_position=False)
raises("control chars refused", ptz.PtzError, ptz.save_preset, "a\nb", 9, save_position=False)
raises("slot out of range", ptz.PtzError, ptz.save_preset, "X", 300, save_position=False)
raises("bool slot refused", ptz.PtzError, ptz.save_preset, "X", True, save_position=False)
n = len(cam.commands())
ptz.delete_preset(1)
check("delete forgets the name only", [p["slot"] for p in ptz.load_presets()] == [3]
      and len(cam.commands()) == n)

# --- camera errors / unreachable
cam.fail_next = True
raises("VISCA error frame raises", ptz.PtzError, ptz.home)
cam.close()
raises("unreachable camera raises", ptz.PtzError, ptz.home)
st = ptz.get_status()
check("status never raises when unreachable", st["reachable"] is False and "error" in st)

print(f"\n=== {FAILED} failed ===" if FAILED else "\n=== all passed ===")
sys.exit(1 if FAILED else 0)

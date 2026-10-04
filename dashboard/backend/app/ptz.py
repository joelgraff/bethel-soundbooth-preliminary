"""PTZ camera control for the PTZOptics PT12X over VISCA-over-TCP.

Why this exists: day-to-day camera moves/preset recall used to need PTZOptics
CMP (heavy, laggy, hard to resize). This talks VISCA directly to the camera on
TCP :5678 and keeps a list of *named* presets on our side. See
docs/dp1-desktop-cockpit-plan.md ("Camera control widget").

Protocol notes (verified against the live camera 2026-10-04 with read-only
inquiries; movement commands are covered by tests/ptz-visca-test.py against a
fake camera, not the real one):
  * TCP :5678 takes raw VISCA frames (no IP header). Replies: ACK 90 4z FF,
    completion 90 5z FF, error 90 6z ee FF, inquiry reply 90 50 ... FF.
  * Power inquiry reads 02=on, 03=standby. Commands sent in standby are
    ignored by the camera, so we refuse them with a clear message instead.

Safety:
  * Pan/tilt/zoom "drive" commands keep moving until told to stop. A watchdog
    stops the camera DRIVE_WATCHDOG_SEC after the last drive command, so the
    frontend must keep re-sending while a button is held; a closed browser or a
    lost mouse-up cannot leave the camera panning.
  * Preset names live in a JSON file here. Saving a position to a camera slot
    overwrites whatever was there (including presets set from CMP or the phone
    app, which we cannot read back) -- callers must confirm first.
"""
from __future__ import annotations

import json
import os
import re
import socket
import threading
from pathlib import Path
from typing import Optional

from .config import _parse_conf

VISCA_PORT = int(os.environ.get("PTZ_VISCA_PORT", "5678"))
CONNECT_TIMEOUT_SEC = 2.0
REPLY_TIMEOUT_SEC = 3.0
DRIVE_WATCHDOG_SEC = 1.5
PAN_SPEED_MAX = 0x18
TILT_SPEED_MAX = 0x14
ZOOM_SPEED_MAX = 7
MAX_SLOT = 254
NAME_MAX_LEN = 40

_PAN = {"left": 0x01, "right": 0x02, "none": 0x03}
_TILT = {"up": 0x01, "down": 0x02, "none": 0x03}
DIRECTIONS = {
    "up": ("none", "up"), "down": ("none", "down"),
    "left": ("left", "none"), "right": ("right", "none"),
    "upleft": ("left", "up"), "upright": ("right", "up"),
    "downleft": ("left", "down"), "downright": ("right", "down"),
    "stop": ("none", "none"),
}


class PtzError(Exception):
    """Camera unreachable, refused a command, or bad input."""


class PtzStandbyError(PtzError):
    """Camera is reachable but in standby; it would ignore commands."""


def camera_ip() -> str:
    ip = os.environ.get("PTZ_CAMERA_IP", "").strip()
    if ip:
        return ip
    conf = _parse_conf(
        Path(os.environ.get(
            "CAMERA_CONF", str(Path.home() / ".config" / "soundbooth" / "camera.conf")
        ))
    )
    ip = conf.get("CAMERA_NETWORK_IP", "").strip()
    if not ip:
        raise PtzError("camera IP not configured (CAMERA_NETWORK_IP in ~/.config/soundbooth/camera.conf)")
    return ip


def presets_path() -> Path:
    return Path(os.environ.get(
        "PTZ_PRESETS_FILE", str(Path.home() / ".config" / "soundbooth" / "ptz-presets.json")
    ))


# ---------------------------------------------------------------- VISCA I/O

def _read_frame(sock: socket.socket) -> bytes:
    buf = b""
    while not buf.endswith(b"\xff"):
        chunk = sock.recv(64)
        if not chunk:
            raise PtzError("camera closed the connection")
        buf += chunk
    return buf


def _visca(cmd: bytes, *, inquiry: bool = False) -> bytes:
    """Send one VISCA frame on a fresh connection; return the final reply.

    Commands: wait for the ACK and (best effort) completion; an error frame
    raises. Inquiries return the 90 50 ... FF payload.
    """
    try:
        sock = socket.create_connection((camera_ip(), VISCA_PORT), timeout=CONNECT_TIMEOUT_SEC)
    except OSError as exc:
        raise PtzError(f"camera unreachable: {exc}") from exc
    with sock:
        sock.settimeout(REPLY_TIMEOUT_SEC)
        try:
            sock.sendall(cmd)
            while True:
                frame = _read_frame(sock)
                kind = frame[1] & 0xF0 if len(frame) > 1 else 0
                if kind == 0x60:
                    raise PtzError(f"camera rejected command (VISCA error {frame.hex()})")
                if inquiry and kind == 0x50:
                    return frame
                if not inquiry and kind in (0x40, 0x50):
                    # ACK is enough for moves; stop reading, don't wait out a slow completion.
                    return frame
        except socket.timeout as exc:
            raise PtzError("camera did not answer in time") from exc
        except OSError as exc:
            raise PtzError(f"camera connection failed: {exc}") from exc


def _nibbles_to_int(data: bytes, signed: bool) -> int:
    value = 0
    for b in data:
        value = (value << 4) | (b & 0x0F)
    if signed and value >= 1 << (4 * len(data) - 1):
        value -= 1 << (4 * len(data))
    return value


def get_power() -> str:
    reply = _visca(bytes.fromhex("81090400ff"), inquiry=True)
    return {0x02: "on", 0x03: "standby", 0x04: "error"}.get(reply[2], "unknown")


def _require_on() -> None:
    if get_power() != "on":
        raise PtzStandbyError("camera is in standby (power it on first; commands are ignored in standby)")


def get_status() -> dict:
    """Never raises: the page polls this and needs to show 'unreachable' calmly."""
    try:
        power = get_power()
    except PtzError as exc:
        return {"reachable": False, "power": "unknown", "error": str(exc)}
    status = {"reachable": True, "power": power}
    if power == "on":
        try:
            pt = _visca(bytes.fromhex("81090612ff"), inquiry=True)
            zm = _visca(bytes.fromhex("81090447ff"), inquiry=True)
            status.update(
                pan=_nibbles_to_int(pt[2:6], True),
                tilt=_nibbles_to_int(pt[6:10], True),
                zoom=_nibbles_to_int(zm[2:6], False),
            )
        except PtzError as exc:
            status["error"] = str(exc)
    return status


# ------------------------------------------------------------------ driving

_watchdog_lock = threading.Lock()
_watchdog: Optional[threading.Timer] = None


def _arm_watchdog() -> None:
    global _watchdog
    with _watchdog_lock:
        if _watchdog is not None:
            _watchdog.cancel()
        _watchdog = threading.Timer(DRIVE_WATCHDOG_SEC, _watchdog_stop)
        _watchdog.daemon = True
        _watchdog.start()


def _disarm_watchdog() -> None:
    global _watchdog
    with _watchdog_lock:
        if _watchdog is not None:
            _watchdog.cancel()
            _watchdog = None


def _watchdog_stop() -> None:
    try:
        _visca(bytes([0x81, 0x01, 0x06, 0x01, 0x01, 0x01, 0x03, 0x03, 0xFF]))
        _visca(bytes([0x81, 0x01, 0x04, 0x07, 0x00, 0xFF]))
    except PtzError:
        pass  # nothing more we can do; the camera also stops on its own after a bit


def _clamp(value: int, lo: int, hi: int) -> int:
    return max(lo, min(hi, int(value)))


def move(direction: str, speed: int = 8) -> dict:
    if direction not in DIRECTIONS:
        raise PtzError(f"unknown direction {direction!r}")
    pan_dir, tilt_dir = DIRECTIONS[direction]
    stopping = direction == "stop"
    if not stopping:
        _require_on()
    pan_speed = _clamp(speed, 1, PAN_SPEED_MAX)
    tilt_speed = _clamp(speed, 1, TILT_SPEED_MAX)
    _visca(bytes([0x81, 0x01, 0x06, 0x01, pan_speed, tilt_speed,
                  _PAN[pan_dir], _TILT[tilt_dir], 0xFF]))
    if stopping:
        _disarm_watchdog()
    else:
        _arm_watchdog()
    return {"ok": True, "direction": direction, "speed": pan_speed}


def zoom(direction: str, speed: int = 3) -> dict:
    if direction not in ("in", "out", "stop"):
        raise PtzError(f"unknown zoom direction {direction!r}")
    if direction != "stop":
        _require_on()
    s = _clamp(speed, 0, ZOOM_SPEED_MAX)
    code = {"in": 0x20 | s, "out": 0x30 | s, "stop": 0x00}[direction]
    _visca(bytes([0x81, 0x01, 0x04, 0x07, code, 0xFF]))
    if direction == "stop":
        _disarm_watchdog()
    else:
        _arm_watchdog()
    return {"ok": True, "zoom": direction}


def home() -> dict:
    _require_on()
    _visca(bytes([0x81, 0x01, 0x06, 0x04, 0xFF]))
    return {"ok": True}


# ------------------------------------------------------------------ presets

def _check_slot(slot: int) -> int:
    if not isinstance(slot, int) or isinstance(slot, bool) or not 0 <= slot <= MAX_SLOT:
        raise PtzError(f"preset slot must be 0-{MAX_SLOT}")
    return slot


def _check_name(name: str) -> str:
    name = (name or "").strip()
    if not name or len(name) > NAME_MAX_LEN or re.search(r"[\x00-\x1f\x7f]", name):
        raise PtzError(f"preset name must be 1-{NAME_MAX_LEN} printable characters")
    return name


def load_presets() -> list[dict]:
    path = presets_path()
    if not path.is_file():
        return []
    try:
        data = json.loads(path.read_text())
        items = data["presets"]
        return [{"name": str(p["name"]), "slot": int(p["slot"])} for p in items]
    except (ValueError, KeyError, TypeError) as exc:
        raise PtzError(f"preset file {path} is unreadable: {exc}") from exc


def _write_presets(presets: list[dict]) -> None:
    path = presets_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps({"presets": presets}, indent=2) + "\n")
    os.replace(tmp, path)


def recall_preset(slot: int) -> dict:
    _check_slot(slot)
    if not any(p["slot"] == slot for p in load_presets()):
        raise PtzError(f"slot {slot} has no name in this app; add it first")
    _require_on()
    _visca(bytes([0x81, 0x01, 0x04, 0x3F, 0x02, slot, 0xFF]))
    return {"ok": True, "slot": slot}


def save_preset(name: str, slot: int, *, save_position: bool, overwrite: bool = False) -> dict:
    """Name a slot; with save_position, also store the camera's CURRENT view in it.

    save_position overwrites the camera's own slot, so it requires overwrite=True
    when this app already names that slot. (A slot we have never named can still
    hold a preset set elsewhere; the caller's confirmation dialog covers that.)
    """
    name = _check_name(name)
    _check_slot(slot)
    presets = load_presets()
    existing = next((p for p in presets if p["slot"] == slot), None)
    clash = next((p for p in presets if p["name"].lower() == name.lower() and p["slot"] != slot), None)
    if clash:
        raise PtzError(f"name {name!r} is already used by slot {clash['slot']}")
    if save_position:
        if existing and not overwrite:
            raise PtzError(f"slot {slot} is already {existing['name']!r}; confirm to overwrite its saved view")
        _require_on()
        _visca(bytes([0x81, 0x01, 0x04, 0x3F, 0x01, slot, 0xFF]))
    if existing:
        existing["name"] = name
    else:
        presets.append({"name": name, "slot": slot})
    presets.sort(key=lambda p: p["slot"])
    _write_presets(presets)
    return {"ok": True, "presets": presets}


def delete_preset(slot: int) -> dict:
    """Forget the name only; the camera's slot is left as it is."""
    _check_slot(slot)
    presets = [p for p in load_presets() if p["slot"] != slot]
    _write_presets(presets)
    return {"ok": True, "presets": presets}

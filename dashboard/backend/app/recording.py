"""Board channel recording — captures specific PreSonus 32SX channels to a
WAV file.

Goes through raw ALSA (hw:3,0 at 64 channels), NOT PipeWire — PipeWire's
capture abstraction for this device silently reads all-zero on every
channel even with confirmed real signal present (both the
input:multichannel-input and pro-audio card profiles). Root-caused live
2026-09-04: see audio-routing/scripts/record-board.sh (the CLI version of
this same approach) and memory presonus_32sx_pipewire_capture_broken.md.

ffmpeg's own ALSA input demuxer can't be used directly either — it only
exposes -sample_rate/-channels (no way to force the S32_LE format this
device requires), and fails to open the device on its own. So arecord does
the hardware capture and pipes raw PCM to ffmpeg for channel selection
(a pan filter) + WAV encoding — the same split record-board.sh uses.

Only one recording at a time — the capture device is exclusive. State is
in-memory (single dashboard backend process); a dashboard restart mid
recording orphans the arecord/ffmpeg pipeline (it keeps running, just
un-trackable from here) rather than attempting crash-recovery bookkeeping
for what is a manually-triggered, operator-supervised action.
"""
from __future__ import annotations

import os
import re
import signal
import subprocess
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

HW_DEVICE = "hw:3,0"
HW_CHANNELS = 64
# Safety cap: auto-stop an unattended recording rather than silently filling
# the disk if someone starts one and forgets about it. 6h is generous for a
# single service; adjust via RECORDING_MAX_DURATION_SEC in dashboard.conf.
DEFAULT_MAX_DURATION_SEC = 6 * 3600
_NAME_RE = re.compile(r"^[A-Za-z0-9_-]{1,64}$")


class RecordingError(RuntimeError):
    pass


@dataclass
class _ActiveRecording:
    process: subprocess.Popen
    channels: list[int]
    filenames: list[str]
    started_at: float
    max_timer: Optional[threading.Timer]


_active: Optional[_ActiveRecording] = None
_lock = threading.Lock()


def _single_file_cmd(channels: list[int], out_file: Path) -> str:
    terms = [f"c{i}=c{ch - 1}" for i, ch in enumerate(channels)]
    pan = f"pan={len(channels)}c|" + "|".join(terms)
    return (
        f"arecord -D {HW_DEVICE} -f S32_LE -r 48000 -c {HW_CHANNELS} -t raw 2>/dev/null | "
        f"ffmpeg -hide_banner -loglevel warning -f s32le -ar 48000 -ac {HW_CHANNELS} "
        f"-i pipe:0 -filter_complex '{pan}' -c:a pcm_s24le -y '{out_file}'"
    )


def _split_files_cmd(channels: list[int], out_dir: Path, base: str) -> tuple[str, list[str]]:
    # One arecord (the device only supports one reader) feeding one ffmpeg
    # that splits the stream N ways internally (asplit) and writes N
    # separate mono files — not N separate arecord/ffmpeg pairs.
    n = len(channels)
    split_labels = "".join(f"[s{i}]" for i in range(n))
    pan_blocks = [f"[s{i}]pan=mono|c0=c{ch - 1}[o{i}]" for i, ch in enumerate(channels)]
    filter_complex = f"asplit={n}{split_labels};" + ";".join(pan_blocks)
    map_args = []
    filenames = []
    for i, ch in enumerate(channels):
        fname = f"{base}-ch{ch}.wav"
        filenames.append(fname)
        map_args.append(f"-map '[o{i}]' -c:a pcm_s24le -y '{out_dir / fname}'")
    cmd = (
        f"arecord -D {HW_DEVICE} -f S32_LE -r 48000 -c {HW_CHANNELS} -t raw 2>/dev/null | "
        f"ffmpeg -hide_banner -loglevel warning -f s32le -ar 48000 -ac {HW_CHANNELS} "
        f"-i pipe:0 -filter_complex '{filter_complex}' " + " ".join(map_args)
    )
    return cmd, filenames


def start_recording(
    *,
    channels: list[int],
    name: Optional[str],
    out_dir: Path,
    split: bool = False,
    max_duration_sec: float = DEFAULT_MAX_DURATION_SEC,
) -> dict:
    global _active
    with _lock:
        if _active is not None and _active.process.poll() is None:
            raise RecordingError("a recording is already in progress")

        if not channels:
            raise RecordingError("select at least one channel")
        bad = [c for c in channels if not (1 <= c <= HW_CHANNELS)]
        if bad:
            raise RecordingError(f"channel(s) out of range 1-{HW_CHANNELS}: {bad}")

        if name:
            if not _NAME_RE.match(name):
                raise RecordingError("name must be letters/digits/-/_ only, max 64 chars")
            base = name
        else:
            base = f"board-{time.strftime('%Y%m%d-%H%M%S')}"

        out_dir.mkdir(parents=True, exist_ok=True)

        if split:
            cmd, filenames = _split_files_cmd(channels, out_dir, base)
            for fname in filenames:
                if (out_dir / fname).exists():
                    raise RecordingError(f"{fname} already exists — choose a different name")
        else:
            out_file = out_dir / f"{base}.wav"
            if out_file.exists():
                raise RecordingError(f"{out_file.name} already exists — choose a different name")
            cmd = _single_file_cmd(channels, out_file)
            filenames = [out_file.name]

        # Shell pipeline run in its own process group (preexec_fn=os.setsid)
        # so SIGINT reaches both arecord and ffmpeg cleanly on stop, same as
        # an interactive Ctrl-C would — ffmpeg finalizes the WAV header(s)
        # on a clean SIGINT, not just SIGKILL.
        proc = subprocess.Popen(cmd, shell=True, executable="/bin/bash", preexec_fn=os.setsid)

        # Popen() returning only means the shell was forked, not that arecord
        # actually opened the capture device. When the board is off/disconnected,
        # arecord's ALSA open fails near-instantly and the whole pipeline exits —
        # without this check, start_recording() reported success regardless, the
        # UI showed "Recording…", and it silently flipped back to Idle on the
        # next status poll with no error ever surfaced to the operator. This is
        # a route handler (sync def), so FastAPI already runs it in a
        # threadpool — this sleep doesn't block the event loop.
        time.sleep(0.4)
        if proc.poll() is not None:
            for fname in filenames:
                fpath = out_dir / fname
                if fpath.exists() and fpath.stat().st_size == 0:
                    fpath.unlink(missing_ok=True)
            raise RecordingError(
                "recording failed to start — check that the PreSonus 32SX is powered on and connected"
            )

        timer = None
        if max_duration_sec and max_duration_sec > 0:
            timer = threading.Timer(max_duration_sec, _auto_stop)
            timer.daemon = True
            timer.start()

        _active = _ActiveRecording(
            process=proc,
            channels=channels,
            filenames=filenames,
            started_at=time.time(),
            max_timer=timer,
        )
        return _status_locked()


def _auto_stop() -> None:
    try:
        stop_recording()
    except RecordingError:
        pass  # already stopped/finished on its own


def stop_recording() -> dict:
    global _active
    with _lock:
        if _active is None or _active.process.poll() is not None:
            raise RecordingError("no recording in progress")

        rec = _active
        if rec.max_timer is not None:
            rec.max_timer.cancel()

        try:
            os.killpg(os.getpgid(rec.process.pid), signal.SIGINT)
        except ProcessLookupError:
            pass
        try:
            rec.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(os.getpgid(rec.process.pid), signal.SIGKILL)
            except ProcessLookupError:
                pass
            rec.process.wait(timeout=5)

        result = {
            "recording": False,
            "filenames": rec.filenames,
            "channels": rec.channels,
            "duration_sec": round(time.time() - rec.started_at, 1),
        }
        _active = None
        return result


def _status_locked() -> dict:
    if _active is None or _active.process.poll() is not None:
        return {"recording": False}
    return {
        "recording": True,
        "filenames": _active.filenames,
        "channels": _active.channels,
        "elapsed_sec": round(time.time() - _active.started_at, 1),
    }


def get_status() -> dict:
    with _lock:
        return _status_locked()


def list_recordings(*, out_dir: Path) -> list[dict]:
    if not out_dir.is_dir():
        return []
    # Exclude the file(s) for a recording still in progress — they already
    # exist on disk (ffmpeg writes as it goes) but aren't "past" yet, and
    # downloading one mid-recording would just get a partial/incomplete file.
    with _lock:
        in_progress = set(_status_locked().get("filenames", []))
    items = []
    for p in sorted(out_dir.glob("*.wav"), key=lambda f: f.stat().st_mtime, reverse=True):
        if p.name in in_progress:
            continue
        st = p.stat()
        items.append({"filename": p.name, "size_bytes": st.st_size, "mtime": st.st_mtime})
    return items


def resolve_recording_path(*, out_dir: Path, filename: str) -> Path:
    # Guard against path traversal — filename must be a bare name with no
    # separators, and must resolve to a real file actually inside out_dir.
    if "/" in filename or "\\" in filename or filename in (".", ".."):
        raise RecordingError("invalid filename")
    resolved_dir = out_dir.resolve()
    path = (out_dir / filename).resolve()
    if not str(path).startswith(str(resolved_dir) + os.sep):
        raise RecordingError("invalid filename")
    if not path.is_file():
        raise RecordingError("recording not found")
    return path

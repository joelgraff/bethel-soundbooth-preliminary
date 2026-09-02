#!/usr/bin/env python3
"""
A/V sync calibrator for the soundbooth FFmpeg path.

Automates the static lip-sync knob (FFMPEG_AUDIO_DELAY_SEC / adelay):

  1. Generate a calibration clip: white flash + simultaneous 1 kHz beep
  2. Re-encode with the same audio filter as start-ffmpeg-capture.sh
  3. Detect flash times vs beep times in the output
  4. Report measured offset and a suggested delay adjustment

Modes
-----
  synthetic   Full offline loop (default). Proves adelay + measurement.
  measure     Analyze an existing media file / MPEG-TS recording.
  capture-udp Record N seconds from the local program UDP feed and measure.
              Only works if a cal pattern (flash+beep) is on ATEM program.
  capture-atem Short exclusive capture of /dev/video0 + ATEM ALSA (stops
              nothing by default; fails if video0 is busy unless --takeover).

Convention
----------
  offset_ms = audio_event_time - video_event_time
    > 0  audio LATE  (reduce FFMPEG_AUDIO_DELAY_SEC)
    < 0  audio EARLY (increase FFMPEG_AUDIO_DELAY_SEC)

Suggested new delay:
  new_delay_sec = max(0, current_delay_sec - offset_ms/1000)
  (adelay delays audio; if audio is still late after delay D, lower D)
"""

from __future__ import annotations

import argparse
import json
import math
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import List, Optional, Sequence, Tuple

FFMPEG = shutil.which("ffmpeg") or "ffmpeg"
FFPROBE = shutil.which("ffprobe") or "ffprobe"

DEFAULT_CONF = Path.home() / ".config/soundbooth/ffmpeg-srt.conf"
# :5000 = ffplay, :5001 = multiview (exclusive unicast). :5002 = free probe tee.
DEFAULT_UDP = (
    "udp://127.0.0.1:5002?fifo_size=5000000&overrun_nonfatal=1&timeout=0"
)
DEFAULT_VIDEO_DEV = "/dev/video0"
DEFAULT_AUDIO_DEV = "plughw:Extreme,0"


# ---------------------------------------------------------------------------
# Config / helpers
# ---------------------------------------------------------------------------

def read_delay_sec(conf: Path) -> float:
    if not conf.is_file():
        return 0.25
    for line in conf.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.strip()
        if line.startswith("FFMPEG_AUDIO_DELAY_SEC="):
            val = line.split("=", 1)[1].strip().strip("'\"")
            try:
                return float(val)
            except ValueError:
                pass
    return 0.25


def delay_ms(sec: float) -> int:
    return max(0, int(round(sec * 1000)))


def audio_filter(sec: float) -> str:
    ms = delay_ms(sec)
    # Match start-ffmpeg-capture.sh production filter
    return f"aresample=48000:async=100,adelay={ms}|{ms}:all=1"


def run(cmd: Sequence[str], **kwargs) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, check=False, **kwargs)


def require_ffmpeg() -> None:
    if not shutil.which("ffmpeg"):
        sys.exit("ERROR: ffmpeg not found in PATH")


# ---------------------------------------------------------------------------
# Generate calibration media (aligned flash + beep)
# ---------------------------------------------------------------------------

def generate_cal(path: Path, duration: float = 12.0, fps: int = 30, period: float = 2.0) -> None:
    """
    Black video; ~2-frame white flash + 50 ms 1 kHz beep every `period` seconds,
    starting at t=1.0 so demux/encode startup is skipped in analysis.
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    # Flash window: first 2 frames of each period after t0
    flash_s = 2.0 / fps
    t0 = 1.0
    # Video: white when mod(t-t0, period) is in [0, flash_s)
    # Use geq on T (seconds) for reliability.
    vexpr = (
        f"if(gte(T\\,{t0})*lt(mod(T-{t0}\\,{period})\\,{flash_s})\\,255\\,0)"
    )
    # Audio: 1 kHz sine when same window (50 ms beep; may span slightly more than flash)
    beep = 0.05
    aexpr = (
        f"if(gte(t\\,{t0})*lt(mod(t-{t0}\\,{period})\\,{beep})\\,"
        f"0.6*sin(2*PI*1000*t)\\,0)"
    )
    cmd = [
        FFMPEG, "-y", "-hide_banner", "-loglevel", "error",
        "-f", "lavfi", "-i",
        f"color=c=black:s=640x360:r={fps}:d={duration},format=yuv420p,"
        f"geq=lum='{vexpr}':cb=128:cr=128",
        "-f", "lavfi", "-i",
        f"aevalsrc=exprs={aexpr}:s=48000:d={duration}",
        "-shortest",
        "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p",
        "-c:a", "pcm_s16le",
        str(path),
    ]
    r = run(cmd)
    if r.returncode != 0 or not path.is_file():
        sys.exit(f"ERROR: failed to generate calibration media → {path}")


# ---------------------------------------------------------------------------
# Encode like production (or capture)
# ---------------------------------------------------------------------------

def encode_like_production(
    src: Path,
    dst: Path,
    delay_sec: float,
    *,
    bitrate_v: str = "2500k",
    bitrate_a: str = "160k",
) -> None:
    af = audio_filter(delay_sec)
    cmd = [
        FFMPEG, "-y", "-hide_banner", "-loglevel", "error",
        "-fflags", "+genpts",
        "-i", str(src),
        "-filter_complex", f"[0:a]{af}[a]",
        "-map", "0:v", "-map", "[a]",
        "-c:v", "libx264", "-preset", "veryfast", "-tune", "zerolatency",
        "-profile:v", "main", "-level", "4.0", "-pix_fmt", "yuv420p",
        "-bf", "0", "-g", "60",
        "-b:v", bitrate_v, "-maxrate", bitrate_v, "-bufsize", "2M",
        "-c:a", "aac", "-b:a", bitrate_a, "-ar", "48000", "-ac", "2",
        "-muxdelay", "0", "-muxpreload", "0",
        "-f", "mpegts", str(dst),
    ]
    r = run(cmd)
    if r.returncode != 0 or not dst.is_file():
        sys.exit(f"ERROR: production-like encode failed → {dst}")


def _pids_listening_udp_port(port: int) -> List[int]:
    r = run(["ss", "-ulnp"], capture_output=True, text=True)
    pids: List[int] = []
    for line in (r.stdout or "").splitlines():
        if f":{port}" not in line:
            continue
        for m in re.finditer(r"pid=(\d+)", line):
            pids.append(int(m.group(1)))
    return pids


def _kill_udp_readers(port: int) -> bool:
    """
    Kill non-encoder readers on a unicast UDP port (socket stays bound under SIGSTOP).
    Returns True if multiview should be restarted afterward.
    """
    need_multiview = False
    for pid in _pids_listening_udp_port(port):
        try:
            cmd = Path(f"/proc/{pid}/cmdline").read_bytes().replace(b"\0", b" ").decode(
                "utf-8", "replace"
            )
        except OSError:
            continue
        if "video0" in cmd or "plughw:Extreme" in cmd:
            continue
        if "ffplay" in cmd:
            continue
        if "5001" in cmd or "booth-multiview" in cmd or "rawvideo" in cmd:
            need_multiview = True
        run(["kill", str(pid)])
        time.sleep(0.2)
        run(["kill", "-9", str(pid)])
    return need_multiview


def _restart_multiview_if_needed(needed: bool) -> None:
    if not needed:
        return
    starter = Path.home() / "bin/start-booth-multiview.sh"
    if starter.is_file():
        print("Restarting booth multiview (preview reader was stolen)…", flush=True)
        run([str(starter)], capture_output=True)


# Expected, harmless noise from joining an H.264/MPEG-TS stream mid-GOP
# (no SPS/PPS seen yet for the frames before the next keyframe). ffmpeg's
# +discardcorrupt already drops these frames from the output — verified
# 2026-08-02 that captured files decode with zero errors afterward — so this
# is cosmetic only. Printed raw, it looks like a real fault; summarize instead.
_BENIGN_STDERR_PATTERNS = (
    "non-existing PPS",
    "decode_slice_header error",
    "no frame!",
    "Last message repeated",
)


def _run_and_summarize_stderr(
    cmd: Sequence[str], context: str
) -> subprocess.CompletedProcess:
    """Run cmd capturing stderr; collapse known-benign mid-GOP-join parser
    noise into a one-line count instead of flooding the console, while still
    printing anything unexpected in full so real problems stay visible."""
    r = run(cmd, capture_output=True, text=True)
    stderr = r.stderr or ""
    benign = 0
    other_lines = []
    for line in stderr.splitlines():
        if any(p in line for p in _BENIGN_STDERR_PATTERNS):
            benign += 1
        elif line.strip():
            other_lines.append(line)
    if benign:
        print(
            f"  ({context}: suppressed {benign} expected mid-GOP-join parser "
            f"message(s) — harmless, already discarded)",
            flush=True,
        )
    for line in other_lines:
        print(f"  [{context}] {line}", flush=True)
    return r


def capture_udp(dst: Path, seconds: float, url: str, *, steal_port: bool = True) -> None:
    """
    Record MPEG-TS from a local UDP tee.

    Prefer port **5002** (free probe tee from ffmpeg-capture). Ports 5000/5001 are
    exclusive unicast and held by ffplay / multiview.
    """
    port = 5002
    m = re.search(r":(\d+)", url)
    if m:
        port = int(m.group(1))

    restore_mv = False
    try:
        if steal_port and port in (5001, 5002):
            # Only steal when bind would fail (reader present)
            if _pids_listening_udp_port(port):
                restore_mv = _kill_udp_readers(port)
                time.sleep(0.4)
        # Mid-stream UDP needs large probe to latch SPS/PPS (same as multiview feeder).
        common = [
            FFMPEG, "-y", "-hide_banner", "-loglevel", "error",
            "-fflags", "+genpts+discardcorrupt",
            "-analyzeduration", "5000000", "-probesize", "5000000",
            "-i", url,
            "-t", f"{seconds:.2f}",
        ]
        cmd = common + ["-c:v", "copy", "-c:a", "copy", "-f", "mpegts", str(dst)]
        r = _run_and_summarize_stderr(cmd, "capture")
        if r.returncode != 0 or not dst.is_file() or dst.stat().st_size < 50000:
            cmd2 = common + [
                "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p",
                "-c:a", "aac", "-ar", "48000", "-ac", "2",
                "-f", "mpegts", str(dst),
            ]
            r = _run_and_summarize_stderr(cmd2, "capture-fallback")
        if r.returncode != 0 or not dst.is_file() or dst.stat().st_size < 50000:
            sys.exit(
                f"ERROR: UDP capture failed or empty ({dst}). "
                "Need ffmpeg-capture tee on :5002 (restart ffmpeg-capture after script update) "
                "or free :5001. ffplay owns :5000."
            )
    finally:
        _restart_multiview_if_needed(restore_mv)


def capture_atem(
    dst: Path,
    seconds: float,
    delay_sec: float,
    video_dev: str,
    audio_dev: str,
) -> None:
    if not Path(video_dev).exists():
        sys.exit(f"ERROR: {video_dev} missing")
    # Busy check
    busy = run(["fuser", video_dev], capture_output=True)
    if busy.returncode == 0:
        sys.exit(
            f"ERROR: {video_dev} busy (usually ffmpeg-capture). "
            "Put a flash+beep cal pattern on ATEM program, then either:\n"
            "  systemctl --user stop ffmpeg-capture ffmpeg-display\n"
            "  av-sync-calibrate.py capture-atem --takeover …\n"
            "or use:  av-sync-calibrate.py capture-udp  (cal must already be on program)"
        )
    af = audio_filter(delay_sec)
    cmd = [
        FFMPEG, "-y", "-hide_banner", "-loglevel", "warning",
        "-fflags", "nobuffer+genpts", "-flags", "low_delay",
        "-thread_queue_size", "1024",
        "-f", "v4l2", "-input_format", "mjpeg",
        "-video_size", "1920x1080", "-framerate", "30",
        "-i", video_dev,
        "-thread_queue_size", "8192",
        "-f", "alsa", "-sample_rate", "48000", "-channels", "2",
        "-i", audio_dev,
        "-t", f"{seconds:.2f}",
        "-filter_complex", f"[1:a]{af}[a]",
        "-map", "0:v", "-map", "[a]",
        "-c:v", "libx264", "-preset", "veryfast", "-tune", "zerolatency",
        "-pix_fmt", "yuv420p", "-bf", "0", "-g", "60",
        "-b:v", "4500k", "-maxrate", "4500k", "-bufsize", "2M",
        "-c:a", "aac", "-b:a", "160k", "-ar", "48000", "-ac", "2",
        "-f", "mpegts", str(dst),
    ]
    r = _run_and_summarize_stderr(cmd, "atem-capture")
    if r.returncode != 0 or not dst.is_file() or dst.stat().st_size < 1000:
        sys.exit(f"ERROR: ATEM capture/encode failed → {dst}")


def capture_atem_takeover(
    dst: Path,
    seconds: float,
    delay_sec: float,
    video_dev: str,
    audio_dev: str,
) -> None:
    """Stop program stack, capture, restart. Live stream interruption."""
    print("WARNING: stopping ffmpeg-capture + ffmpeg-display for exclusive capture…", flush=True)
    run(["systemctl", "--user", "stop", "ffmpeg-capture.service", "ffmpeg-display.service"])
    time.sleep(1.5)
    try:
        # Wait for device free
        for _ in range(20):
            busy = run(["fuser", video_dev], capture_output=True)
            if busy.returncode != 0:
                break
            time.sleep(0.25)
        capture_atem(dst, seconds, delay_sec, video_dev, audio_dev)
    finally:
        print("Restarting ffmpeg-capture + ffmpeg-display…", flush=True)
        run(["systemctl", "--user", "start", "ffmpeg-capture.service", "ffmpeg-display.service"])


# ---------------------------------------------------------------------------
# Measure: flash times (video) vs beep times (audio)
# ---------------------------------------------------------------------------

def extract_luma_series(media: Path, fps_hint: float = 30.0) -> Tuple[List[float], List[float], float]:
    """
    Return (times_sec, mean_luma_0_255, fps).
    Downscale heavily for speed.

    CAVEAT (untested edge case, flagged 2026-08-02): times are computed as
    frame_index / fps using one nominal fps probed via ffprobe, not real
    per-frame PTS. This is fine for synthetic mode (constant-fps lavfi
    source, verified). But the ATEM Mini Extreme on this system has been
    observed to change its actual frame rate mid-capture (e.g. UVC driver
    logged "changed the time per frame from 1/30 to 1/24" during a live
    session — see ffmpeg-capture journal, 2026-08-02). If that drift happens
    during a capture-udp/capture-atem measurement, video-event times here
    would be computed against the wrong fps for the drifted portion, silently
    skewing the measured offset with no warning. If a live measurement looks
    inconsistent across pairs (unlike synthetic mode's pairs, which should
    all read the same offset), suspect this before trusting the result.
    """
    # Probe fps
    pr = run(
        [
            FFPROBE, "-v", "error", "-select_streams", "v:0",
            "-show_entries", "stream=r_frame_rate,avg_frame_rate",
            "-of", "default=noprint_wrappers=1",
            str(media),
        ],
        capture_output=True,
        text=True,
    )
    fps = fps_hint
    for line in (pr.stdout or "").splitlines():
        if "frame_rate=" in line:
            rate = line.split("=", 1)[1].strip()
            if "/" in rate:
                num, den = rate.split("/", 1)
                try:
                    if float(den) != 0:
                        fps = float(num) / float(den)
                except ValueError:
                    pass
            else:
                try:
                    fps = float(rate)
                except ValueError:
                    pass
            if fps > 1:
                break

    w, h = 160, 90
    cmd = [
        FFMPEG, "-hide_banner", "-loglevel", "error",
        "-i", str(media),
        "-an", "-vf", f"scale={w}:{h},format=gray",
        "-f", "rawvideo", "pipe:1",
    ]
    r = run(cmd, capture_output=True)
    if r.returncode != 0 or not r.stdout:
        sys.exit(f"ERROR: could not decode video from {media}")
    frame_size = w * h
    raw = r.stdout
    n = len(raw) // frame_size
    times: List[float] = []
    lumas: List[float] = []
    for i in range(n):
        chunk = raw[i * frame_size : (i + 1) * frame_size]
        # mean luma
        total = sum(chunk)
        lumas.append(total / frame_size)
        times.append(i / fps if fps > 0 else float(i))
    return times, lumas, fps


def extract_audio_pcm(media: Path, sr: int = 48000) -> Tuple[List[int], int]:
    cmd = [
        FFMPEG, "-hide_banner", "-loglevel", "error",
        "-i", str(media),
        "-vn", "-ac", "1", "-ar", str(sr),
        "-f", "s16le", "pipe:1",
    ]
    r = run(cmd, capture_output=True)
    if r.returncode != 0 or not r.stdout:
        sys.exit(f"ERROR: could not decode audio from {media}")
    n = len(r.stdout) // 2
    samples = list(struct.unpack("<" + "h" * n, r.stdout[: n * 2]))
    return samples, sr


def find_flash_times(
    times: Sequence[float],
    lumas: Sequence[float],
    *,
    min_interval: float = 1.2,
) -> List[float]:
    """Rising-edge onset of each bright flash (not peak of the run)."""
    if not lumas:
        return []
    sorted_l = sorted(lumas)
    med = sorted_l[len(sorted_l) // 2]
    mx = sorted_l[-1]
    if mx - med < 20:
        return []
    thr = med + 0.45 * (mx - med)
    flashes: List[float] = []
    i = 0
    n = len(lumas)
    while i < n:
        if lumas[i] >= thr:
            onset_t = times[i]
            j = i
            while j < n and lumas[j] >= thr * 0.85:
                j += 1
            if not flashes or (onset_t - flashes[-1]) >= min_interval:
                flashes.append(onset_t)
            i = j
        else:
            i += 1
    return flashes


def find_beep_times(
    samples: Sequence[int],
    sr: int,
    *,
    min_interval: float = 1.2,
    beep_window_ms: float = 10.0,
) -> List[float]:
    """Rising-edge onset of each beep via short-window RMS."""
    if not samples:
        return []
    win = max(1, int(sr * (beep_window_ms / 1000.0)))
    hop = max(1, win // 2)
    energies: List[Tuple[float, float]] = []  # (t_start, rms)
    for start in range(0, len(samples) - win, hop):
        chunk = samples[start : start + win]
        acc = 0.0
        for s in chunk:
            acc += s * s
        rms = math.sqrt(acc / win)
        t = start / sr  # window start ≈ onset when threshold crossed
        energies.append((t, rms))
    if not energies:
        return []
    vals = sorted(e for _, e in energies)
    med = vals[len(vals) // 2]
    mx = vals[-1]
    if mx < 200 or mx < med * 3:
        return []
    thr = med + 0.35 * (mx - med)
    thr = max(thr, med * 4, 500.0)

    beeps: List[float] = []
    i = 0
    n = len(energies)
    while i < n:
        t, e = energies[i]
        if e >= thr:
            onset_t = t
            j = i
            while j < n and energies[j][1] >= thr * 0.7:
                j += 1
            if not beeps or (onset_t - beeps[-1]) >= min_interval:
                beeps.append(onset_t)
            i = j
        else:
            i += 1
    return beeps


def pair_events(
    video_t: Sequence[float],
    audio_t: Sequence[float],
    max_skew: float = 1.5,
) -> List[Tuple[float, float, float]]:
    """Return list of (v_t, a_t, offset_ms)."""
    pairs: List[Tuple[float, float, float]] = []
    used_a = set()
    for vt in video_t:
        best = None
        best_abs = None
        for i, at in enumerate(audio_t):
            if i in used_a:
                continue
            d = at - vt
            if abs(d) > max_skew:
                continue
            if best_abs is None or abs(d) < best_abs:
                best_abs = abs(d)
                best = (i, at, d)
        if best is not None:
            i, at, d = best
            used_a.add(i)
            pairs.append((vt, at, d * 1000.0))
    return pairs


def median(xs: Sequence[float]) -> float:
    if not xs:
        return float("nan")
    s = sorted(xs)
    n = len(s)
    if n % 2:
        return s[n // 2]
    return 0.5 * (s[n // 2 - 1] + s[n // 2])


def measure_media(media: Path) -> dict:
    times, lumas, fps = extract_luma_series(media)
    samples, sr = extract_audio_pcm(media)
    flashes = find_flash_times(times, lumas)
    beeps = find_beep_times(samples, sr)
    pairs = pair_events(flashes, beeps)
    offsets = [p[2] for p in pairs]
    med = median(offsets) if offsets else float("nan")
    return {
        "media": str(media),
        "fps": fps,
        "duration_est_sec": times[-1] if times else 0.0,
        "flash_count": len(flashes),
        "beep_count": len(beeps),
        "pair_count": len(pairs),
        "flash_times_sec": [round(t, 4) for t in flashes],
        "beep_times_sec": [round(t, 4) for t in beeps],
        "pairs": [
            {"video_s": round(v, 4), "audio_s": round(a, 4), "offset_ms": round(o, 1)}
            for v, a, o in pairs
        ],
        "offset_ms_median": None if math.isnan(med) else round(med, 1),
        "offset_ms_mean": (
            None if not offsets else round(sum(offsets) / len(offsets), 1)
        ),
        "luma_max": round(max(lumas), 1) if lumas else None,
        "luma_median": round(median(lumas), 1) if lumas else None,
    }


def interpret(result: dict, current_delay_sec: float, tolerance_ms: float = 40.0) -> dict:
    off = result.get("offset_ms_median")
    out = {
        "current_delay_sec": current_delay_sec,
        "tolerance_ms": tolerance_ms,
        "in_sync": None,
        "verdict": "unknown",
        "suggested_delay_sec": current_delay_sec,
        "suggested_delta_sec": 0.0,
        "note": "",
        # Synthetic mode overrides this to False in main(): the suggested
        # delay there is computed against an intentionally injected known
        # delay, not a real measured path skew, so it must not be read as an
        # actual recommendation (see main()'s synthetic block + print_report).
        "suggested_delay_meaningful": True,
    }
    if result.get("pair_count", 0) < 2:
        out["verdict"] = "no_markers"
        out["note"] = (
            "Fewer than 2 flash/beep pairs. For live paths, put a flash+beep "
            "calibration pattern on ATEM program (or use synthetic mode)."
        )
        return out
    assert off is not None
    # offset > 0 → audio late relative to video in the measured stream
    # adelay increases audio latency → to fix late audio, decrease delay
    new_delay = max(0.0, current_delay_sec - (off / 1000.0))
    # Round to 10 ms
    new_delay = round(new_delay * 100) / 100.0
    out["suggested_delay_sec"] = new_delay
    out["suggested_delta_sec"] = round(new_delay - current_delay_sec, 3)
    if abs(off) <= tolerance_ms:
        out["in_sync"] = True
        out["verdict"] = "ok"
        out["note"] = f"|offset|={abs(off):.0f} ms ≤ {tolerance_ms:.0f} ms tolerance"
    else:
        out["in_sync"] = False
        side = "LATE" if off > 0 else "EARLY"
        out["verdict"] = "audio_" + side.lower()
        out["note"] = (
            f"Audio is {side} by ~{abs(off):.0f} ms vs video. "
            f"Suggested FFMPEG_AUDIO_DELAY_SEC={new_delay:.2f} "
            f"(Δ {out['suggested_delta_sec']:+.2f}s)."
        )
    return out


def print_report(result: dict, interp: dict, *, json_out: bool = False) -> None:
    if json_out:
        print(json.dumps({"measure": result, "interpret": interp}, indent=2))
        return
    print("=== A/V sync measurement ===")
    print(f"  media:     {result['media']}")
    print(f"  flashes:   {result['flash_count']}  beeps: {result['beep_count']}  pairs: {result['pair_count']}")
    if result.get("pairs"):
        for p in result["pairs"]:
            print(
                f"    pair  v={p['video_s']:.3f}s  a={p['audio_s']:.3f}s  "
                f"offset={p['offset_ms']:+.1f} ms"
            )
    off = result.get("offset_ms_median")
    print(f"  median offset (audio−video): {off} ms" if off is not None else "  median offset: n/a")
    print(f"  current FFMPEG_AUDIO_DELAY_SEC: {interp['current_delay_sec']}")
    print(f"  verdict: {interp['verdict']}")
    print(f"  in_sync: {interp['in_sync']}")
    if interp.get("suggested_delay_meaningful", True):
        print(f"  suggested delay: {interp['suggested_delay_sec']} s")
    else:
        print(
            "  suggested delay: n/a in this mode — measured against an "
            "intentionally injected delay, not a real path skew; do not use "
            "as a recommendation (see note)"
        )
    print(f"  {interp['note']}")


def write_conf_delay(conf: Path, delay_sec: float) -> None:
    delay_sec = max(0.0, round(float(delay_sec) * 100) / 100.0)
    conf.parent.mkdir(parents=True, exist_ok=True)
    line = f"FFMPEG_AUDIO_DELAY_SEC={delay_sec}"
    if conf.is_file():
        text = conf.read_text(encoding="utf-8", errors="replace")
        if re.search(r"^FFMPEG_AUDIO_DELAY_SEC=", text, re.M):
            text = re.sub(
                r"^FFMPEG_AUDIO_DELAY_SEC=.*$",
                line,
                text,
                count=1,
                flags=re.M,
            )
        else:
            text = text.rstrip() + "\n" + line + "\n"
        conf.write_text(text, encoding="utf-8")
    else:
        conf.write_text(line + "\n", encoding="utf-8")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main(argv: Optional[Sequence[str]] = None) -> int:
    require_ffmpeg()
    p = argparse.ArgumentParser(description="Soundbooth A/V sync calibrator")
    p.add_argument(
        "mode",
        nargs="?",
        default="synthetic",
        choices=["synthetic", "measure", "capture-udp", "capture-atem", "write-cal"],
        help="synthetic (default) | measure | capture-udp | capture-atem | write-cal",
    )
    p.add_argument("--conf", type=Path, default=DEFAULT_CONF)
    p.add_argument("--delay", type=float, default=None, help="Override delay seconds for encode")
    p.add_argument("--duration", type=float, default=12.0)
    p.add_argument("--input", type=Path, help="Media for measure mode")
    p.add_argument("--udp", default=DEFAULT_UDP)
    p.add_argument("--video-dev", default=DEFAULT_VIDEO_DEV)
    p.add_argument("--audio-dev", default=DEFAULT_AUDIO_DEV)
    p.add_argument("--takeover", action="store_true", help="capture-atem: stop/restart program stack")
    p.add_argument("--tolerance-ms", type=float, default=40.0)
    p.add_argument("--work-dir", type=Path, default=None)
    p.add_argument("--keep", action="store_true", help="Keep work files")
    p.add_argument("--apply", action="store_true", help="Write suggested delay to conf (no restart)")
    p.add_argument("--apply-restart", action="store_true", help="Write conf and restart ffmpeg stack")
    p.add_argument("--json", action="store_true")
    args = p.parse_args(argv)

    current = args.delay if args.delay is not None else read_delay_sec(args.conf)
    work = args.work_dir or Path(tempfile.mkdtemp(prefix="av-sync-"))
    work.mkdir(parents=True, exist_ok=True)
    media: Path

    try:
        if args.mode == "synthetic":
            cal = work / "cal_source.mkv"
            out = work / "cal_encoded.ts"
            print(f"Generating calibration source → {cal}", flush=True)
            generate_cal(cal, duration=args.duration)
            print(
                f"Encoding with production audio filter "
                f"(delay={current}s → adelay={delay_ms(current)}ms)…",
                flush=True,
            )
            encode_like_production(cal, out, current)
            media = out
            # For synthetic: we *expect* audio delayed by ~current*1000 ms
            # relative to source-aligned events. Measurement of output should
            # show offset ≈ +delay_ms (audio late by design).
            result = measure_media(media)
            interp = interpret(result, current, args.tolerance_ms)
            # The suggested_delay_sec interpret() just computed is measured
            # against our own intentionally-injected delay, not a real path
            # skew — it is not a real recommendation. Flag it so print_report
            # doesn't show a raw number that looks like advice.
            interp["suggested_delay_meaningful"] = False
            # Synthetic: measured offset should equal applied adelay (+ small
            # encode residual). Compare to expected; also report residual as if
            # it were a live "path skew" for tooling confidence.
            off = result.get("offset_ms_median")
            expected = float(delay_ms(current))
            if off is not None and result.get("pair_count", 0) >= 2:
                err = off - expected
                interp["synthetic_expected_offset_ms"] = expected
                interp["synthetic_error_ms"] = round(err, 1)
                # Allow one frame (~33ms) + AAC/window quantize headroom
                synth_tol = max(args.tolerance_ms, 50.0)
                if abs(err) <= synth_tol:
                    interp["adelay_ok"] = True
                    interp["verdict"] = "synthetic_ok"
                    interp["in_sync"] = True
                    interp["note"] = (
                        f"Synthetic: measured offset {off:.0f} ms ≈ applied "
                        f"adelay {expected:.0f} ms (err {err:+.0f} ms ≤ {synth_tol:.0f}). "
                        f"Filter + detector OK. Live ATEM USB skew needs "
                        f"capture-udp/capture-atem with cal on program."
                    )
                else:
                    interp["adelay_ok"] = False
                    interp["verdict"] = "synthetic_mismatch"
                    interp["in_sync"] = False
                    interp["note"] = (
                        f"Synthetic: expected ~{expected:.0f} ms audio lag from adelay, "
                        f"measured {off:.0f} ms (err {err:+.0f} ms)."
                    )
            print_report(result, interp, json_out=args.json)
            if not args.json:
                print(f"  work dir: {work}")
            # --apply on synthetic would zero out delay to "fix" intentional lag — refuse
            if args.apply or args.apply_restart:
                print(
                    "NOTE: --apply ignored in synthetic mode "
                    "(would fight intentional adelay). "
                    "Use capture-udp / capture-atem for live ATEM skew.",
                    flush=True,
                )
            return 0 if interp.get("in_sync") else 2

        if args.mode == "measure":
            if not args.input:
                sys.exit("ERROR: measure mode needs --input FILE")
            media = args.input
            result = measure_media(media)
            interp = interpret(result, current, args.tolerance_ms)
            print_report(result, interp, json_out=args.json)
            return _maybe_apply(args, interp)

        if args.mode == "write-cal":
            out = args.input or (work / "soundbooth-av-cal.mkv")
            generate_cal(out, duration=args.duration)
            print(f"Wrote calibration media: {out}")
            print(
                "Play this full-screen into an ATEM input (or FreeShow→ATEM), "
                "set as program, then:  av-sync-calibrate capture-udp"
            )
            if not args.keep and args.work_dir is None and out.parent == work:
                pass  # keep file path printed; still in work
            return 0

        if args.mode == "capture-udp":
            media = work / "udp_capture.ts"
            print(f"Capturing {args.duration:.0f}s from {args.udp}…", flush=True)
            capture_udp(media, args.duration, args.udp)
            result = measure_media(media)
            interp = interpret(result, current, args.tolerance_ms)
            print_report(result, interp, json_out=args.json)
            if not args.json:
                print(f"  work dir: {work}")
            return _maybe_apply(args, interp)

        if args.mode == "capture-atem":
            media = work / "atem_capture.ts"
            print(
                f"ATEM capture {args.duration:.0f}s delay={current}s "
                f"(cal flash+beep must be on program)…",
                flush=True,
            )
            if args.takeover:
                capture_atem_takeover(
                    media, args.duration, current, args.video_dev, args.audio_dev
                )
            else:
                capture_atem(
                    media, args.duration, current, args.video_dev, args.audio_dev
                )
            result = measure_media(media)
            interp = interpret(result, current, args.tolerance_ms)
            print_report(result, interp, json_out=args.json)
            if not args.json:
                print(f"  work dir: {work}")
            return _maybe_apply(args, interp)

    finally:
        if not args.keep and args.work_dir is None:
            # only auto-clean mkdtemp
            if str(work).startswith(tempfile.gettempdir()):
                shutil.rmtree(work, ignore_errors=True)

    return 0


def _maybe_apply(args: argparse.Namespace, interp: dict) -> int:
    if not (args.apply or args.apply_restart):
        return 0 if interp.get("in_sync") else 2
    if interp.get("verdict") == "no_markers":
        print("ERROR: cannot apply — no cal markers detected", flush=True)
        return 2
    new_d = float(interp["suggested_delay_sec"])
    write_conf_delay(args.conf, new_d)
    print(f"Wrote {args.conf}: FFMPEG_AUDIO_DELAY_SEC={new_d}", flush=True)
    if args.apply_restart:
        run(
            [
                "systemctl",
                "--user",
                "restart",
                "ffmpeg-capture.service",
                "ffmpeg-display.service",
            ]
        )
        print("Restarted ffmpeg-capture + ffmpeg-display", flush=True)
    return 0 if interp.get("in_sync") else 0  # apply succeeded


if __name__ == "__main__":
    sys.exit(main())

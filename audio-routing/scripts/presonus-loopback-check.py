#!/usr/bin/env python3
"""Verify the PreSonus 32SX is actually receiving and processing our audio.

This is the only check we have that observes the FAR side of the USB link.
Everything else (amixer clock validity, kernel log, ALSA hw_ptr) only
proves something about the host side — and on 2026-09-04 all three of them
read healthy while the board was silently not rendering audio at all.

How it works: capture what we're SENDING (Mixer.monitor) and what the board
is SENDING BACK (its USB Send channels, raw ALSA) simultaneously, then
cross-correlate the amplitude envelopes. The board's own DSP routes our
USB Return signal out to Send channels, so a healthy board returns our own
audio to us at a small fixed latency (~70ms measured). A dead or stalled
board returns uncorrelated noise.

Measured on a known-good board: correlation 0.79 at 70ms on the loopback
channels, 0.06 at a random lag on an unrelated room-mic channel. Threshold
of 0.3 separates those cleanly.

Exit codes:
    0  healthy   — loopback confirmed, board is processing our audio
    1  FAILED    — sending real signal but nothing correlates: board is not
                   processing audio even if every host-side check says fine
    2  inconclusive — not enough signal being sent to judge (e.g. music
                   paused/silent). NOT a failure; caller should skip.
    3  error     — couldn't capture (device busy/absent). Caller should
                   treat as suspicious but distinguish from a clean FAILED.

Usage: presonus-loopback-check.py [--seconds N] [--verbose]
"""
from __future__ import annotations

import argparse
import struct
import subprocess
import sys
import tempfile
import os

HW_CHANNELS = 64
RATE = 48000
# Only channels 1-32 carry meaningful USB Sends on this board; the rest are
# padding in the fixed 64-channel stream.
SCAN_CHANNELS = 32
BLOCK = 480          # 10ms envelope blocks
MAX_LAG_BLOCKS = 60  # search 0..600ms of round-trip latency
CORR_THRESHOLD = 0.30
# Below this RMS (fraction of full scale) on the sent signal, there isn't
# enough program material to correlate against — report inconclusive
# rather than crying wolf during silence between songs.
MIN_SENT_RMS = 0.0005


def capture(seconds: float, tmpdir: str) -> tuple[str, str]:
    sent = os.path.join(tmpdir, "sent.raw")
    heard = os.path.join(tmpdir, "heard.raw")
    # Start the monitor tap first, then the hardware capture; the hardware
    # capture's fixed -d duration bounds the whole thing.
    p = subprocess.Popen(
        ["parec", "--device=Mixer.monitor", "--format=s16le",
         f"--rate={RATE}", "--channels=2"],
        stdout=open(sent, "wb"), stderr=subprocess.DEVNULL,
    )
    try:
        r = subprocess.run(
            ["arecord", "-D", "hw:3,0", "-f", "S32_LE", "-r", str(RATE),
             "-c", str(HW_CHANNELS), "-t", "raw", "-d", str(int(seconds + 1)),
             heard],
            stderr=subprocess.DEVNULL, timeout=seconds + 15,
        )
        rc = r.returncode
    except subprocess.TimeoutExpired:
        rc = 1
    finally:
        p.terminate()
        try:
            p.wait(timeout=5)
        except subprocess.TimeoutExpired:
            p.kill()
    if rc != 0:
        raise RuntimeError("arecord failed to capture from the board")
    return sent, heard


def envelope(sig, block):
    return [sum(sig[i * block:(i + 1) * block]) / block
            for i in range(len(sig) // block)]


def normalize(x):
    if not x:
        return x
    mean = sum(x) / len(x)
    c = [a - mean for a in x]
    mag = sum(a * a for a in c) ** 0.5
    return [a / mag for a in c] if mag > 0 else c


def write_comparison_wav(path, sent, v, chan_idx, nh):
    """Stereo clip: LEFT = what we sent, RIGHT = what the board returned.

    Each side is normalized independently — the returned signal comes back
    at roughly 1% of full scale, so without this the right channel would be
    inaudible next to the left.
    """
    import wave
    back = [v[f * HW_CHANNELS + chan_idx] for f in range(nh)]
    n = min(len(sent), len(back))
    if n == 0:
        raise ValueError("no frames to write")
    ps = max(1, max(abs(x) for x in sent[:n]))
    pb = max(1, max(abs(x) for x in back[:n]))
    gs = (32767 * 0.85) / ps
    gb = (32767 * 0.85) / pb
    with wave.open(path, "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(RATE)
        frames = bytearray()
        for i in range(n):
            l = int(max(-32768, min(32767, sent[i] * gs)))
            r = int(max(-32768, min(32767, back[i] * gb)))
            frames += struct.pack("<hh", l, r)
        w.writeframes(bytes(frames))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--seconds", type=float, default=3.0)
    ap.add_argument("--verbose", action="store_true")
    ap.add_argument("--save-wav", metavar="PATH",
                    help="write a stereo comparison clip: LEFT = what we "
                         "sent the board, RIGHT = what it returned on the "
                         "best-correlating Send channel. Both normalized, "
                         "so the round-trip delay is audible.")
    args = ap.parse_args()

    with tempfile.TemporaryDirectory() as tmpdir:
        try:
            sent_path, heard_path = capture(args.seconds, tmpdir)
        except Exception as exc:
            print(f"ERROR: capture failed: {exc}")
            return 3

        raw = open(sent_path, "rb").read()
        ns = len(raw) // 2
        if ns < BLOCK * 4:
            print("ERROR: sent capture too short")
            return 3
        s = struct.unpack(f"<{ns}h", raw[:ns * 2])
        # Correlation works on magnitudes (envelope); the WAV clip needs the
        # signed samples or it comes out rectified and distorted.
        sent_signed = [s[i * 2] for i in range(ns // 2)]
        sent = [abs(x) for x in sent_signed]

        sent_rms = (sum(v * v for v in sent) / len(sent)) ** 0.5 / 32768
        if sent_rms < MIN_SENT_RMS:
            print(f"INCONCLUSIVE: little/no audio being sent "
                  f"(rms={sent_rms:.6f}) — nothing to correlate against")
            return 2

        raw2 = open(heard_path, "rb").read()
        frame = HW_CHANNELS * 4
        nh = len(raw2) // frame
        if nh < BLOCK * 4:
            print("ERROR: board capture too short")
            return 3
        v = struct.unpack(f"<{nh * HW_CHANNELS}i", raw2[:nh * frame])

        env_sent = normalize(envelope(sent, BLOCK))
        best_ch, best_corr, best_lag = None, 0.0, 0
        for c in range(SCAN_CHANNELS):
            heard = [abs(v[f * HW_CHANNELS + c]) for f in range(nh)]
            env_heard = normalize(envelope(heard, BLOCK))
            L = min(len(env_sent), len(env_heard))
            if L <= MAX_LAG_BLOCKS + 10:
                continue
            for lag in range(MAX_LAG_BLOCKS):
                corr = sum(env_sent[i] * env_heard[i + lag]
                           for i in range(L - lag))
                if corr > best_corr:
                    best_ch, best_corr, best_lag = c + 1, corr, lag * 10

        if args.verbose:
            print(f"sent_rms={sent_rms:.6f} best_ch={best_ch} "
                  f"corr={best_corr:.3f} lag={best_lag}ms")

        if args.save_wav and best_ch is not None:
            try:
                write_comparison_wav(args.save_wav, sent_signed, v, best_ch - 1, nh)
                print(f"clip: {args.save_wav} (L=sent, R=returned ch{best_ch})")
            except Exception as exc:   # never let clip-writing mask the verdict
                print(f"note: could not write clip: {exc}")

        if best_corr >= CORR_THRESHOLD:
            print(f"OK: loopback confirmed on ch{best_ch} "
                  f"(corr={best_corr:.2f} at {best_lag}ms)")
            return 0

        print(f"FAILED: no loopback correlation (best={best_corr:.2f} on "
              f"ch{best_ch}) while sending real signal (rms={sent_rms:.6f}) "
              f"— board is not processing our audio")
        return 1


if __name__ == "__main__":
    sys.exit(main())

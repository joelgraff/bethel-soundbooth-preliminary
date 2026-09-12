---
name: av-sync-calibrate
description: >
  Manual A/V lip-sync calibration for the soundbooth FFmpeg encode path
  (FFMPEG_AUDIO_DELAY_SEC / adelay). Run only when the user explicitly asks
  to calibrate lip-sync, measure A/V offset, test adelay, or runs
  /av-sync-calibrate. Never run automatically on diagnostics, health checks,
  or routine AV troubleshooting unless the user requests this test.
---

# A/V sync calibrate (manual test)

**Not automatic.** This skill is an **on-demand** booth test. Do not invoke it
during `soundbooth-health`, boot checks, or general troubleshooting unless the
user explicitly requests lip-sync calibration or `/av-sync-calibrate`.

## Prerequisites

1. Read `SYSTEM-STATE.md` (audio delay policy, FFmpeg tees).
2. Tool: `~/bin/av-sync-calibrate`  
   Source: `audio-routing/scripts/av-sync-calibrate.py`  
   Install if missing:
   ```bash
   install -m 0755 \
     "$HOME/soundbooth-project/audio-routing/scripts/av-sync-calibrate.py" \
     "$HOME/bin/av-sync-calibrate.py"
   ln -sfn "$HOME/bin/av-sync-calibrate.py" "$HOME/bin/av-sync-calibrate"
   ```
3. Live delay conf: `~/.config/soundbooth/ffmpeg-srt.conf` → `FFMPEG_AUDIO_DELAY_SEC`
   (booth-calibrated default **0.25** as of 2026-07-26).

## What it measures

- Calibration media: **white flash + simultaneous 1 kHz beep** (known events).
- Offset: `audio_event_time − video_event_time` (ms).
  - **> 0** → audio LATE → lower `FFMPEG_AUDIO_DELAY_SEC`
  - **< 0** → audio EARLY → raise `FFMPEG_AUDIO_DELAY_SEC`
- Production filter (must match encode):  
  `aresample=48000:async=100,adelay=MS|MS:all=1`

## Validated 2026-08-02

Ran synthetic mode and capture-udp against the live production encode to
confirm the tool actually works, not just that it runs:

- **Synthetic mode confirmed accurate**: measured offset matched a known
  injected 250ms delay to within 15ms, with zero variance across all 6
  flash/beep pairs. Detector + production filter logic are sound.
- **capture-udp confirmed working end-to-end** against a real live encode
  (captured from `:5002`, correctly reported `no_markers` since no cal
  pattern was on program — the expected result).
- **If you see a wall of `non-existing PPS` / `decode_slice_header error` /
  `no frame!` during capture-udp or capture-atem**: that used to print raw
  to the console and looked like a real fault. Fixed 2026-08-02 — it's now
  collapsed into one summary line ("suppressed N expected mid-GOP-join
  parser messages"). This noise is a normal artifact of joining an
  in-progress H.264 stream mid-GOP; `+discardcorrupt` already drops those
  frames, so the captured file itself decodes cleanly. If you still see raw
  walls of this after an update, the deployed `~/bin/av-sync-calibrate.py`
  is stale — reinstall from the repo.
- **Synthetic mode's "suggested delay" used to print a raw, misleading
  number** (e.g. "0.0s") that looked like a real recommendation but was only
  an artifact of testing against the intentionally-injected delay. Fixed
  2026-08-02 — it now prints `n/a in this mode` with an explanation instead.
- **Known unverified caveat (live modes only, not synthetic)**: offset
  measurement computes video-frame timestamps as `frame_index / fps` using
  one nominal frame rate, not real per-frame PTS. This booth's ATEM Mini
  Extreme has been observed to drift its actual frame rate mid-session
  (UVC driver logged "changed the time per frame from 1/30 to 1/24" during
  a live capture, 2026-08-02). If that drift happens during a
  capture-udp/capture-atem measurement, the computed offset could be
  skewed without any warning from the tool. Sanity check: in synthetic
  mode every flash/beep pair reads the *same* offset (proven above); if a
  live measurement's pairs disagree with each other noticeably, suspect a
  frame-rate hiccup during that capture and retry rather than trusting the
  number.

## Modes (pick with user intent)

### 1) Synthetic (safe, offline — default first step)

Proves **adelay + detector** without touching ATEM or the live stack.

```bash
~/bin/av-sync-calibrate
# or:
~/bin/av-sync-calibrate synthetic --duration 12
```

**Success:** `verdict: synthetic_ok`, measured offset ≈ applied adelay (± ~50 ms).  
Does **not** write conf. Does **not** measure dual-USB ATEM path skew.

### 2) Live path (needs cal pattern on ATEM program)

Only when the user can put flash+beep on program (or accepts a short program interruption for `capture-atem --takeover`).

```bash
# Generate cal media
~/bin/av-sync-calibrate write-cal --input "$HOME/Videos/soundbooth-av-cal.mkv"

# Operator: play full-screen into an ATEM input → cut to program, then:
~/bin/av-sync-calibrate capture-udp --duration 12
```

- Capture uses free encode tee **UDP :5002** (not :5000 ffplay / :5001 multiview).
- `:5002` requires current `start-ffmpeg-capture.sh` tee (restart encode once after install if missing).

**Success:** ≥ 2 flash/beep pairs; `|offset_ms_median|` within tolerance (default 40 ms) → `in_sync: true`.

Suggest apply only if user wants:

```bash
~/bin/av-sync-calibrate capture-udp --apply          # write conf only
~/bin/av-sync-calibrate capture-udp --apply-restart  # write conf + restart ffmpeg-capture + ffmpeg-display
```

**Never** `--apply` / `--apply-restart` without explicit user approval (interrupts livestream display / SRT briefly on restart).

### 3) Measure existing file

```bash
~/bin/av-sync-calibrate measure --input /path/to/recording.ts
```

### 4) Exclusive ATEM capture (interrupts program stack)

```bash
# Stops ffmpeg-capture + ffmpeg-display, captures, restarts — confirm first
~/bin/av-sync-calibrate capture-atem --takeover --duration 12
```

## Agent procedure when this skill is invoked

1. Confirm user wants this **manual** test (skill already implies yes if they ran `/av-sync-calibrate`).
2. Prefer **synthetic** first unless they asked for live ATEM/path calibration.
3. Run the command; report median offset, verdict, suggested delay.
4. If live path: remind that cal must be on ATEM program; do not invent lip-sync from speech alone.
5. Persist changes only if user approves:
   - conf `FFMPEG_AUDIO_DELAY_SEC`
   - script default in `start-ffmpeg-capture.sh` if that is the new booth baseline
   - `SYSTEM-STATE.md` / `STATUS.md` when live delay changes
6. Do **not** schedule, cron, or add this to boot / `soundbooth-health` / autostart.

## Available-test inventory note

This is an **optional ops test**, listed next to health/smoke:

| Test | When | Auto? |
|------|------|-------|
| `soundbooth-health.sh` | Boot / ops diagnostics | Yes if user asks diagnostics |
| `smoke-health.sh` | CI-ish smoke | On request |
| **`av-sync-calibrate`** | Lip-sync / adelay confidence | **Never automatic** |

## Related paths

- Script: `audio-routing/scripts/av-sync-calibrate.py`
- Encode: `audio-routing/scripts/start-ffmpeg-capture.sh`
- Conf: `~/.config/soundbooth/ffmpeg-srt.conf`
- Docs: `audio-routing/README.md` (A/V calibrator section), `audio-routing/tests/manual-test.md`
- Tees: `:5000` program · `:5001` multiview · `:5002` cal probe

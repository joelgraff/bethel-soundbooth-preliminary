# Equipment & Physical Connections

**Purpose:** the thing that was missing — `SYSTEM-STATE.md` documents how the
software routes signal once it's digital, but nothing tracked in git said what
physical box plugs into which physical port. This is that document: equipment
inventory, cable-by-cable signal chain, and a pointer to the mixer channel map.
Supersedes `~/booth_ai/booth-context.md` (not in git, stale since May 2026 —
still references retired VLC services and the removed `System` sink) as the
canonical equipment list; that file can be retired once this is verified.

**Living document — update when a connection changes.** Unlike `SYSTEM-STATE.md`
(software/services) this is about physical reality: cables, ports, boxes. If
you rewire something, this is the file that goes stale, not that one.

**Status:** seeded from `SYSTEM-STATE.md`, `STATUS.md`, and the old
`booth-context.md` — everything below marked ✅ is already documented
elsewhere and just consolidated here. Everything marked **NEEDS VERIFICATION**
is a gap: nobody has confirmed it against the physical booth. Fill those in
directly, or dictate them in a session and have it written up here.

---

## 1. Equipment inventory

### Core computer

| Item | Detail | Source |
|------|--------|--------|
| Motherboard | ASRock B450M Pro4 | ✅ SYSTEM-STATE.md |
| CPU | Ryzen 5 3600X | ✅ |
| RAM | ~40 GB | ✅ |
| GPU | AMD Radeon PRO WX 3200 (Polaris12), 4× HDMI out — no VP9 HW decode, H.264/HEVC VAAPI OK | ✅ |

### Audio

| Item | Qty | Role | Source |
|------|-----|------|--------|
| PreSonus StudioLive 32SX | 1 | Main mixer, USB to booth PC | ✅ |
| NSB 16.8 stagebox | 2 | Stage input snake → mixer | ✅ (booth-context.md; **NEEDS VERIFICATION**: which NSB feeds which mixer input range, and how the two are networked/daisy-chained to the 32SX) |
| Earmix 16M | 7 | Personal monitor mixers | ✅ (booth-context.md; **NEEDS VERIFICATION**: how many are actually in active use, and their network/AVB or analog patch back to the board) |
| Behringer DI, 8-channel | 1 | Direct injection boxes for stage instruments | ✅ (booth-context.md; **NEEDS VERIFICATION**: which stage inputs run through it vs. direct to a stagebox) |
| Roland TD-27 (V-Drums module) | 1 | Electronic drum kit sound module | ✅ (booth-context.md; **NEEDS VERIFICATION**: output routing — stereo pair? which stagebox/channel?) |
| Crown XLS202 | 1 | House amplifier | ✅ (booth-context.md; **NEEDS VERIFICATION**: which mixer output(s) feed it, and which speaker zone it drives) |
| Peavey GPS 2600 | 1 | Subwoofer amplifier | ✅ (booth-context.md; **NEEDS VERIFICATION**: which mixer output feeds it) |
| Bose 251 Environmental Speakers | 8 | House speakers, split across 2 channels (mono per channel) | ✅ (booth-context.md; **NEEDS VERIFICATION**: physical zone/channel split — which 4 are on which amp channel) |

### Video / capture

| Item | Qty | Role | Source |
|------|-----|------|--------|
| Blackmagic ATEM Mini Extreme | 1 | Video switcher/capture; UVC → `/dev/video0`, Pulse audio slave; Ethernet control (IP in `~/.config/soundbooth/atem.conf`, not in git) | ✅ SYSTEM-STATE.md |
| PTZOptics PT12X-SDI-xx-G2 | 1 | Program camera; SDI out → ATEM program input; also has a separate IP control/preview path (`~/.config/soundbooth/camera.conf`) | ✅ |
| 85" Sony Bravia TV | 2 | Sanctuary displays | ✅ |
| GoFanco 1080p HDMI-over-Cat transceivers | multi-port hub + 1 stage unit | HDMI extension over Cat cable; longest run ~200 ft; known reliability weak point (planned upgrade: HDBaseT/Blackbird) | ✅ |

**NEEDS VERIFICATION — not yet documented anywhere:** any other cameras
(wide/confidence shots?), wireless mic receivers/transmitters and channel
count, in-ear monitor transmitters, any lighting-console or DMX gear sharing
the booth, and the make/model of the outside/lobby monitors mentioned
elsewhere as "outside monitors" in `SYSTEM-STATE.md`'s hardware table.

### Maintenance workstation

| Item | Role | Source |
|------|------|--------|
| MacBook (model/year not yet recorded) | Runs ATEM Software Control, PreSonus Universal Control, (optionally) H2R Layouts — none have a Linux build. **Explicitly non-operational**: nothing in `soundbooth.target` or the livestream path depends on it. | ✅ STATUS.md 2026-09-14 |

**NEEDS VERIFICATION:** exact MacBook model/year (for the eventual
`SYSTEM-STATE.md` write-up mentioned in STATUS.md), and how it currently
reaches the ATEM/PreSonus — same Wi-Fi as the booth PC? Wired? Confirm it
only ever talks to the ATEM over the network (`atem.conf`'s address), never
USB, while `ffmpeg-capture.service` is running (USB contention risk already
flagged in STATUS.md).

---

## 2. Physical signal chain

### Video path

```
PTZOptics camera (SDI out)
        │
        ▼
ATEM Mini Extreme (program bus)
        │
        ├─ UVC/USB ──► booth PC (/dev/video0) ──► ffmpeg-capture.service
        │                                              │
        │                                    (see SYSTEM-STATE.md for the
        │                                     digital fan-out from here:
        │                                     DP-4 TV, dashboard previews,
        │                                     SRT relay to Subsplash)
        │
        └─ Ethernet (control only, not video) ──► atem.conf IP
                                                   (ATEM Software Control,
                                                    from the MacBook or the
                                                    booth PC's network)
```

GPU → display outputs (already in `SYSTEM-STATE.md`, repeated here since it's
the tail end of the same physical chain):

| Connector | Monitor/target | Path | Run type |
|-----------|-----------------|------|----------|
| DP-1 | SAM S34CG50 ultrawide (booth) | direct | short, in-booth |
| DP-2 | HXA BMD HDMI (FreeShow Primary → sanctuary) | via GoFanco extender | **NEEDS VERIFICATION**: run length |
| DP-3 | LKV/HDbitT-style (FreeShow Stage) | via GoFanco extender | **NEEDS VERIFICATION**: run length |
| DP-4 | SII HDMI TV (program → sanctuary) | via GoFanco extender | up to ~200 ft (longest run) |

**NEEDS VERIFICATION:** which physical GoFanco transmitter/receiver pair
serves which connector (the multi-port hub vs. the single stage unit), and
where each Cat run physically terminates (which TV, which wall plate).

### Audio path — stage to FOH

```
Stage instruments/mics/DI
        │
        ▼
NSB 16.8 stagebox(es) ──► [NEEDS VERIFICATION: snake/network path] ──► PreSonus 32SX
        │
        ▼
32SX mixer (channel assignments: see docs/mixer-channel-map.md, in progress)
        │
        ├─ USB ──► booth PC (software audio return path — see SYSTEM-STATE.md
        │           "Audio policy" for the presonus-foh-bridge chain)
        │
        └─ house output(s) ──► [NEEDS VERIFICATION which physical output]
                 │
                 ├─► Crown XLS202 ──► Bose 251 speakers (4? — NEEDS VERIFICATION)
                 └─► Peavey GPS 2600 ──► subwoofer(s)
```

**NEEDS VERIFICATION (the real gap this doc exists to close):**
- Which physical inputs on which NSB stagebox carry which stage sources
  (vocals, acoustic guitar ×2 per the in-progress channel map, drums via the
  TD-27 module, DI'd instruments via the Behringer 8-ch DI, etc.)
- Which 32SX output bus(es) feed the Crown XLS202 and Peavey GPS 2600
- Earmix 16M monitor mixer patch — analog sends off the board, or a digital
  network (AVB/Dante-style) between the 16Ms and the 32SX
- Any patch bay or wall-panel connectors between the stage and the booth

### Audio path — software to FOH

Already fully documented in `SYSTEM-STATE.md` → "Audio policy" (Mixer virtual
sink → `presonus-foh-bridge.service` → ALSA → PreSonus USB return 1–2 → board
channel fader). Not repeated here — that's the *digital* half of this same
physical chain; this document picks up in the previous section, where sound
leaves the board.

---

## 3. Mixer channel configuration

**Separate, in-progress effort — see `docs/mixer-channel-map.md`** (not yet
created as of 2026-09-14; being built from board photos in a planning
session). Once that file exists, cross-link it from here rather than
duplicating channel-by-channel detail in two places.

Known so far (per STATUS.md 2026-09-14):
- Channels 1–16 and 25–32 plus FX returns/aux/tape/talkback captured from
  photos.
- Still needed: a third photo covering channels 17–24.
- **Needs verification at the board:** channel 26 reads unlabeled/blank —
  confirm intentional. Channels 2 and 4 both read "Ac Gtar" — confirm two
  acoustic guitar channels is correct, not a misread.

---

## 4. How to fill the gaps

This doc is only useful once the **NEEDS VERIFICATION** items are resolved.
Two ways to do that:

1. **Dictate it** in a chat session (this one or another) — read off labels,
   trace cables, or describe the patch from memory, and have it written up
   here directly.
2. **Photos**, same pattern as the mixer channel map — photograph the back of
   the stageboxes, the amp rack, the GoFanco units and their cable labels (if
   labeled), and a session can transcribe them into the tables above.

Either way, edit this file directly rather than starting a parallel doc —
it's the one place both digital (`SYSTEM-STATE.md`) and physical signal paths
are meant to be cross-referenced from.

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
| NSB 16.8 stagebox | 2 | Stage inputs onto the AVB network | ✅ (**NEEDS VERIFICATION**: which NSB carries which mixer channel range) |
| PreSonus AVB switch | ? | Hub for the whole PreSonus audio network — stageboxes, EarMixes and the console all connect through it | ✅ operator, 2026-09-14 (**NEEDS VERIFICATION**: how many, exact model, and whether any live in the booth rack rather than on stage) |
| Earmix 16M | 7 | Personal monitor mixers, fed over AVB via the switch — **not** from console aux outs | ✅ operator, 2026-09-14 (**NEEDS VERIFICATION**: how many in active use; daisy-chained or one switch port each) |
| Behringer DI, 8-channel | 1 | Direct injection boxes for stage instruments | ✅ (booth-context.md; **NEEDS VERIFICATION**: which stage inputs run through it vs. direct to a stagebox) |
| Roland TD-27 (V-Drums module) | 1 | Electronic drum kit sound module | ✅ (booth-context.md; **NEEDS VERIFICATION**: output routing — stereo pair? which stagebox/channel?) |
| Crown XLS202 | 1 | House amplifier | ✅ (booth-context.md; **NEEDS VERIFICATION**: which mixer output(s) feed it, and which speaker zone it drives) |
| Peavey GPS 2600 | 1 | Subwoofer amplifier | ✅ (booth-context.md; **NEEDS VERIFICATION**: which mixer output feeds it) |
| Bose 251 Environmental Speakers | 8 | House speakers, split across 2 channels (mono per channel) | ✅ (booth-context.md; **NEEDS VERIFICATION**: physical zone/channel split — which 4 are on which amp channel) |

### Video / capture

| Item | Qty | Role | Source |
|------|-----|------|--------|
| Blackmagic ATEM Mini Extreme | 1 | Video switcher/capture; UVC → `/dev/video0`, Pulse audio slave; Ethernet control (IP in `~/.config/soundbooth/atem.conf`, not in git). **All inputs are HDMI — it has no SDI input**, hence the converter below | ✅ SYSTEM-STATE.md |
| SDI → HDMI converter | 1 | Converts the camera's SDI run to HDMI for the ATEM's **Camera 2** input | ✅ operator, 2026-09-14 (**NEEDS VERIFICATION**: make/model, and whether it sits in the booth rack or out at the camera) |
| PTZOptics PT12X-SDI-xx-G2 | 1 | Program camera; SDI out → converter → ATEM Camera 2; also has a separate IP control/preview path (`~/.config/soundbooth/camera.conf`) | ✅ |
| 85" Sony Bravia TV | 2 | **FOH displays, facing the congregation** — fed by DP-2 (FreeShow Primary) | ✅ operator, 2026-09-14 |
| BOH TV | 1 | **Faces the pulpit** — confidence feed for whoever is speaking; fed by DP-4 (program). Distinct from the DP-3 FreeShow Stage monitor | ✅ operator, 2026-09-14 (**NEEDS VERIFICATION**: make/model/size) |
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

**Connectivity (confirmed, operator 2026-09-14): Wi-Fi only.** The MacBook has
**no USB connection to anything** — it reaches exactly two things over
Wi-Fi: the ATEM (ATEM Software Control) and the booth PC's web dashboard.
That also settles the `/dev/video0` USB-contention concern raised in
STATUS.md: with no USB path at all, it can't contend with `ffmpeg-capture`.

**NEEDS VERIFICATION:** exact MacBook model/year, for the eventual
`SYSTEM-STATE.md` write-up mentioned in STATUS.md.

---

## 2. Physical signal chain

> **Rendered diagrams:** `docs/signal-chain.yaml` holds this same topology as
> structured data, rendered as Stage / Sound Booth diagrams on the dashboard's
> Reference Docs page. That file is the topology source of truth — if it and
> the prose below ever disagree, one of them is wrong; fix both rather than
> letting them fork. Links marked `needs-verification` there are the same gaps
> flagged below.

### Video path

```
INPUTS
  PTZOptics camera (SDI out)
          │  SDI coax
          ▼
  SDI → HDMI converter        (the ATEM Mini Extreme has NO SDI input —
          │                    every input on it is HDMI)
          └──► Camera 2 ─┐
                         │
  booth PC DP-2 ────► Camera 3 ─┐   (same feed as the FOH Bravias, so
     (FreeShow Primary)         │    slides can be switched to program)
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
                                                    from the MacBook over
                                                    Wi-Fi, or the booth PC)
```

GPU → display outputs (already in `SYSTEM-STATE.md`, repeated here since it's
the tail end of the same physical chain):

| Connector | Monitor/target | Path | Run type |
|-----------|-----------------|------|----------|
| DP-1 | SAM S34CG50 ultrawide (booth) | direct | short, in-booth |
| DP-2 | FreeShow Primary → **the two FOH Bravias (facing the congregation)**, *and* back into the ATEM on **Camera 3** | via GoFanco extender + a tap to the ATEM | **NEEDS VERIFICATION**: run length |
| DP-3 | LKV/HDbitT-style (FreeShow Stage) | via GoFanco extender | **NEEDS VERIFICATION**: run length |
| DP-4 | SII HDMI TV (program → the BOH TV facing the pulpit) | via GoFanco extender | up to ~200 ft (longest run) |

**DP-2 feeds two destinations.** As well as driving the two FOH Bravias, the
same output returns to the ATEM as **Camera 3** — so FreeShow Primary
(slides, lower thirds) can be switched into the program feed and therefore
into the livestream and the back-of-house TVs, not just shown on the front
screens (operator, 2026-09-14).

**Sanctuary display layout** (confirmed, operator 2026-09-14): the **two 85"
Sony Bravias are the FOH pair, facing the congregation** (fed by DP-2,
FreeShow Primary). There is **one BOH TV facing the pulpit** — a confidence
feed for whoever is speaking — fed by DP-4, the program output. Note this is
a *different* display from the FreeShow Stage confidence monitor on DP-3,
which serves the stage/musicians.

**NEEDS VERIFICATION:** where the Camera 3 feed is tapped — a splitter off
DP-2 ahead of the GoFanco hub, or a spare output on the hub itself. Which
physical GoFanco transmitter/receiver pair serves which connector (the
multi-port hub vs. the single stage unit), and where each Cat run physically
terminates. Also whether DP-4's split feeds anything besides the single BOH
TV — the dashboard's own tile calls it "Split that feeds the back-of-house
TVs" (plural), and SYSTEM-STATE separately mentions "outside monitors", so
there may be more on that leg than the one pulpit-facing display.

### Audio path — stage to FOH

```
Stage instruments / mics / DI / TD-27
        │  (analog XLR)
        ▼
NSB 16.8 stagebox A + B
        │
        │  ┌──────────── PreSonus AVB network ────────────┐
        └──┤  NSB A ─┐                                    │
           │  NSB B ─┼─► PreSonus AVB switch ─► 32SX      │
           │  EarMix ┘        (hub for all of it)         │
           └──────────────────────────────────────────────┘
        │
        ▼
32SX mixer (channel assignments: see docs/mixer-channel-map.md, in progress)
        │
        ├─ USB ──► booth PC (software audio return path — see SYSTEM-STATE.md
        │           "Audio policy" for the presonus-foh-bridge chain)
        │
        ├─ ch 21 ◄── booth PC analog line-out (contingency feed — see the
        │             channel-number conflict below)
        │
        └─ house output(s) ──► [NEEDS VERIFICATION which physical output]
                 │
                 ├─► Crown XLS202 ──► Bose 251 speakers (4? — NEEDS VERIFICATION)
                 └─► Peavey GPS 2600 ──► subwoofer(s)
```

The EarMix units are **not** fed from console aux outs — they sit on the AVB
network alongside the stageboxes, and the switch is the hub for all of it
(operator, 2026-09-14).

> **Booth PC analog line-out → board channel 21** (resolved 2026-09-14). This
> was originally patched to **channel 32** and later re-patched to 21, but the
> repo was never updated — `lineout-fallback.service`'s `Description=` and
> five comments in `start-lineout-fallback.sh` all still said 32, including
> the operational guidance a mid-service operator would actually read ("if
> channel 32 is up while USB audio is also running…", "Board channel 32 is a
> BALANCED input"). All corrected, with a note in the script header so older
> commits and notes mentioning ch 32 remain interpretable. Nothing functional
> depended on the number — every reference was documentary.

**NEEDS VERIFICATION (the real gap this doc exists to close):**
- Which physical inputs on which NSB stagebox carry which stage sources
  (vocals, acoustic guitar ×2 per the in-progress channel map, drums via the
  TD-27 module, DI'd instruments via the Behringer 8-ch DI, etc.)
- Which NSB carries which mixer channel range over AVB
- How many AVB switches there are, their model, and where each physically sits
- Whether the EarMixes daisy-chain or take one switch port each
- Which 32SX output bus(es) feed the Crown XLS202 and Peavey GPS 2600
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

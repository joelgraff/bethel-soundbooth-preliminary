# Soundbooth project rules (Grok)

You are working on the **church soundbooth** machine and its setup system.

## Shared knowledge (required)

At the start of any non-trivial task in this tree:

1. Read **`SYSTEM-STATE.md`** (canonical architecture, routing policy, displays, services).
2. Read **`STATUS.md`** (what is done / next).
3. For volunteer-facing text, align with **`portal/content/`** and do not contradict SYSTEM-STATE.

Do **not** invent alternate audio policies or display assignments. If reality differs from SYSTEM-STATE, **update SYSTEM-STATE.md** (and STATUS) after verifying.

## Where work goes

| Kind of work | Location |
|--------------|----------|
| Scripts, WirePlumber, tests | `audio-routing/` (+ install copies under `~/bin` when live) |
| Web dashboard (backend, agent bridge, units manifest) | `dashboard/` |
| Provision / rebuild / backup | `replicability/` |
| Volunteer docs | `portal/` |
| Investigation notes | `docs/` |
| Cross-session progress | `STATUS.md` |
| Architecture truth | `SYSTEM-STATE.md` |

## Audio / video policies (summary)

- Software audio → **Presonus 32SX** (Mixer virtual / WirePlumber → AUX0/1).
- **Program exception** → FFmpeg SRT + **ffplay on DP-4** (HDMI TV audio, not Mixer).
- FreeShow Stage vs Primary vs program TV (DP-4) are **different outputs** — do not conflate them.
- Prefer `systemctl --user` for FFmpeg stack / qpwgraph / `ensure-audio-routes`; no VLC services.
- FOH silent with apps on Mixer → `~/bin/ensure-audio-routes.sh` (Mixer→Presonus links).

## Session modes

User may open separate sessions for diagnostics, troubleshooting, or features. Regardless of mode:

- Load shared state from SYSTEM-STATE + STATUS.
- Prefer additive, reversible changes; back up configs before PipeWire/WirePlumber edits.
- When finishing a chunk of work: update STATUS.md; update SYSTEM-STATE.md if the live system changed.

## Safety

- This machine may be used for live services — avoid destructive disk/audio experiments without confirmation when risk is high.
- Large media stays outside this git tree.

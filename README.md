# Soundbooth Project

This directory contains the organized work for making the church soundbooth computer stable, replicable, and usable by staff/volunteers.

## Focus Areas (in priority order)

1. **audio-routing/** — Automatic routing of all software audio sources to the Presonus 32SX (VLC exception for HDMI TVs).
2. **replicability/** — From-fresh-Ubuntu provisioning scripts + the seed of the "soundbooth-setup" system (with future source/sink discovery and auto-config).
3. **portal/** — Local-only wiki/portal (TiddlyWiki or static) for non-expert users. Future AI-assist possible.

## Quick Start (on this machine)

- See `replicability/REBUILD.md` for full from-scratch instructions.
- Audio rules and scripts live under `audio-routing/`.
- Portal content and site are under `portal/`.
- Run helpers from `scripts/` or the subdirs.

## Structure

See the master plan (in the Grok session or copied here) for the full intended layout.

All artifacts created for these initiatives should land here so the entire "setup system" can be versioned (git recommended) and deployed to a fresh machine.

## Status

See `STATUS.md` for current progress across sessions.

## License / Notes

Internal church soundbooth tooling. Keep sensitive show content out of this tree.

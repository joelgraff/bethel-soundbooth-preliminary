# Replicability & Soundbooth Setup System

This area produces the ability to recreate the entire rig from a fresh Ubuntu install and becomes the home of the evolving "soundbooth-setup" tool.

## Current Deliverables (basic framework)
- `provision/` — install.sh + package lists + backup/restore. The seed that can be run on a new machine.
- `REBUILD.md` — step-by-step from bare Ubuntu.
- `discovery/` — placeholder for future pw-dump / source-sink inspection tools.
- `docs/`

## Long-term
The scripts here + the audio-routing rules + portal content should be consumable by a single `soundbooth-setup` deploy that also performs discovery and applies configuration.

Git root of the whole project is recommended at the `soundbooth-project/` level.

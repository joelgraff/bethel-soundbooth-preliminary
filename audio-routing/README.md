# Audio Routing

Goal: Every app that produces audio (Spotify, browsers, etc.) is automatically sent to the Presonus 32SX board.

**Hard rule**: Default route = Presonus mixer.  
**Exception**: VLC stays on AMD HDMI outputs for the church TVs.

## Contents
- `wireplumber/` — Lua policy scripts for auto linking (WirePlumber 0.4 style).
- `scripts/ensure-audio-routes.sh` — On-demand repair / belt-and-suspenders tool.
- `tests/` — Manual verification steps.

See the master plan for implementation details and the exact target virtual sink choice.

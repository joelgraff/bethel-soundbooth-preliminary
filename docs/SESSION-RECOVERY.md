# Session Recovery Handoff

**Recovered session ID:** `019f3379-9910-7140-a338-5548dbed8fc1`  
**Title:** Church Soundbooth Computer: Diagnosing Multiple System Issues  
**Last updated:** 2026-07-12 ~16:04 UTC  
**Model for resume:** `grok-4.5` (available)

## Resume command

From `/home/soundbooth`:

```bash
grok --resume 019f3379-9910-7140-a338-5548dbed8fc1
```

Or in TUI: `/resume` → pick **Church Soundbooth Computer…**  
If model error: `/model grok-4.5` then continue.

## Where work left off

### Done / working
1. **Audio routing (priority 1):** WirePlumber rule + ensure script + services; reboot test OK — Spotify/FreeShow route to Presonus board.
2. **qpwgraph:** crash-on-start fixed via wrapper; restart clean (no crash).
3. **Project scaffold:** `~/soundbooth-project/` with audio-routing, replicability, portal.
4. **FreeShow webm issue diagnosed:** VP9 not HW-accelerated on AMD WX 3200; use H.264 MP4. Tools: `~/bin/convert-for-freeshow.sh`, `~/bin/start-freeshow.sh`.

### Next (not finished)
- Replicability track deeper (provision polish, git init if desired)
- Portal content expansion / volunteer docs
- FreeShow lag: convert webm media; optional yt-dlp MP4 defaults
- Further rig hardening / full cold-boot verification as needed

See also: `~/soundbooth-project/STATUS.md`, plan at session `plan.md`.

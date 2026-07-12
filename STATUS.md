# Soundbooth Project — Cross-Session Status

Updated: 2026-07-12 (continued in session after model-update recovery)

## Priority Order
1. Audio routing (default all sources → Presonus except VLC)
2. Replicability + soundbooth-project bootstrap + setup system foundation
3. Portal / wiki (local only) + docs

## Current State (2026-07-12)

### audio-routing/
- [x] WirePlumber Lua rule installed (`~/.config/wireplumber/main.lua.d/50-soundbooth-software-to-mixer.lua`)
- [x] `ensure-audio-routes.sh`, `start-qpwgraph.sh` in `~/bin` + project
- [x] Live verify: Spotify / FreeShow route to Presonus after reboot/restart
- [x] qpwgraph start crash mitigated (wrapper); restart clean
- [x] FreeShow webm stutter root cause: WX 3200 has no VP9 HW decode (VAAPI H.264/HEVC only)
- [x] Converted Downloads webms → H.264/AAC MP4:
  - `Downloads/Skit Guys - Being Mom [H-Kw6cOwh2c].mp4` (h264 854x480)
  - `Downloads/yt-dlp_linux (2)/Girls Captain…2026….mp4` (h264 3840x2160)
- [x] Batch converter: `~/bin/convert-for-freeshow-batch.sh`
- [x] FreeShow-friendly downloader: `~/bin/yt-dlp-freeshow.sh`
- [ ] Optional: virtual sink consolidation if duplication still causes issues
- [ ] Optional: FreeShow audio device selection audit vs Mixer virtual

### replicability/
- [x] Project scaffold + provision (install.sh, package lists, REBUILD.md)
- [x] `backup-configs.sh` / `restore-configs.sh` (+ `~/bin/soundbooth-*-configs.sh`)
- [x] First config backup written under `replicability/backups/`
- [x] Git init + initial commit of `soundbooth-project/` (local identity)
- [ ] Practice restore dry-run on spare/VM when convenient
- [ ] webui/ollama cleanup when ready

### portal/
- [x] Skeleton + quick-reference (audio policy, FreeShow webm/mp4, backup cmds)
- [ ] More content from `booth_ai/booth-context.md` (startup checklists, diagrams)
- [ ] Desktop launcher polish / local serve on high port if desired

## How to pick up next session
```bash
cd ~/soundbooth-project && cat STATUS.md
# Media for FreeShow: use the .mp4 files (not .webm) listed above
# Backup: ~/bin/soundbooth-backup-configs.sh
```

## Next Recommended
1. In FreeShow, swap playlists to the new `.mp4` files and confirm no stutter
2. Expand portal volunteer checklists from booth-context.md
3. Cold-boot full-rig verification (Presonus on first)
4. Optional: remove unused open-webui/ollama

## Notes
- Policy: all software audio → Presonus StudioLive 32SX; VLC → HDMI TVs.
- Hardware: Ryzen 5 3600X, AMD Radeon PRO WX 3200, PreSonus StudioLive 32SX.
- Recovered prior session ID: `019f3379-9910-7140-a338-5548dbed8fc1` (see docs/SESSION-RECOVERY.md).

# Soundbooth Project — Cross-Session Status

Updated: 2026-07-12 (session recovery after Grok model update)

## Recovered session
- **ID:** `019f3379-9910-7140-a338-5548dbed8fc1`
- **Title:** Church Soundbooth Computer: Diagnosing Multiple System Issues
- **Resume:** `grok --resume 019f3379-9910-7140-a338-5548dbed8fc1` (model: `grok-4.5`)
- **Handoff:** `docs/SESSION-RECOVERY.md`

## Priority Order
1. Audio routing (default all sources → Presonus except VLC)
2. Replicability + soundbooth-project bootstrap + setup system foundation
3. Portal / wiki (local only) + docs

## Current State (2026-07-12)

### audio-routing/
- [x] Project dir scaffold + wireplumber/ + scripts/ + tests/
- [x] WirePlumber Lua rule (`50-soundbooth-software-to-mixer.lua`) installed to `~/.config`
- [x] `ensure-audio-routes.sh` (project + `~/bin`)
- [x] **Live verify:** reboot test — Spotify routes to board; FreeShow + Spotify route properly after restart
- [x] **qpwgraph:** start crash mitigated via `start-qpwgraph.sh` wrapper; restart clean (no crash dialog)
- [x] FreeShow webm stutter diagnosed (GPU has no VP9 HW decode on WX 3200 / Polaris12)
- [x] `~/bin/convert-for-freeshow.sh` + `~/bin/start-freeshow.sh`
- [ ] Full services / duplicate virtual sinks cleanup (if still needed)
- [ ] Batch convert remaining webm media if desired
- [ ] Contribute full verified flow to portal (partial: quick-reference updated)

### replicability/
- [x] Project directory fully scaffolded under `~/soundbooth-project/`
- [x] provision/ with install.sh + apt-packages.txt + snap-packages.txt
- [x] REBUILD.md (from-fresh-Ubuntu steps + project bootstrap)
- [ ] backup-configs.sh / restore-configs.sh
- [ ] Git init of project dir
- [ ] webui/ollama removal integrated into install.sh (prompt)

### portal/
- [x] Basic skeleton (`index.html` + `content/quick-reference.md`)
- [x] webm vs mp4 FreeShow guidance in quick-reference
- [ ] More seed content from booth-context.md / audio policy checklists
- [ ] Local-only serving / desktop launcher polish

### Shared / Docs
- [x] README.md + STATUS.md
- [x] SESSION-RECOVERY.md
- [ ] More diagrams / content

## Last assistant offer (interrupted by model update)
Would you like to:
- Convert specific webm files now?
- Batch converter / media folder watcher?
- FreeShow audio output device selection vs Mixer virtual?
- Other routing work?

## Next Recommended
1. Convert FreeShow webm media to H.264 MP4 (or batch)
2. Create backup-configs.sh / restore-configs.sh
3. Optional: git init the project dir
4. Flesh out portal content for volunteers
5. Cold-boot full-rig verification when convenient

## Notes
- Policy: all software audio → Presonus StudioLive 32SX; VLC exception → HDMI TVs.
- Hardware: Ryzen 5 3600X, AMD Radeon PRO WX 3200, PreSonus StudioLive 32SX.
- All work under `~/soundbooth-project/` for portability.
- Large media / shows remain outside this tree.
- Open-webui (ollama test) is unused and can be cleaned in replicability work.

# Manual Audio Routing Test Procedure

## Prerequisites
- Presonus 32SX powered on and visible (`pactl list short sinks | grep -i presonus`)
- qpwgraph running (or the service active)
- This script available: `~/bin/ensure-audio-routes.sh`

## Test Steps (Software Sources → Board)

1. Restart the audio policy stack:
   ```
   systemctl --user restart wireplumber pipewire
   sleep 3
   ```

2. Launch a software source (do **not** use VLC for this test):
   - Start Spotify and play a track, **or**
   - Open Vivaldi/Firefox and play YouTube (or any HTML5 audio).

3. Run the repair helper:
   ```
   ~/bin/ensure-audio-routes.sh
   ```

4. Verify routing:
   - In qpwgraph: look for the app node (spotify, Chromium-..., etc.) connected toward "Mixer" or the Presonus "playback_AUX*".
   - Run:
     ```
     pw-link -l | grep -iE 'spotify|chromium|vivaldi|mixer|presonus'
     ```
   - Check that audio is audible on the main sound system / board meters (not just local speakers).

5. Reboot test:
   - Reboot the machine (with Presonus already on).
   - Repeat steps 2-4 after login. The WP rule + qpwgraph -a -x should do most of the work.

## VLC Exception Check (do separately)

1. Start VLC (the capture one or any).
2. Confirm its audio is **not** forced to the Mixer / board in the same way (it should still go to the HDMI path for TVs).
3. If you accidentally matched VLC, update the rule to be more specific and restart wireplumber.

## If Something Is Wrong

- Re-apply the rule file:
  ```
  cp soundbooth-project/audio-routing/wireplumber/50-*.lua ~/.config/wireplumber/main.lua.d/
  systemctl --user restart wireplumber
  ```
- Run ensure script with --dry-run first.
- Use `pavucontrol` to manually move a stream as a temporary workaround.
- Check `journalctl --user -u wireplumber -e` for errors in the Lua rule.

## Success Criteria
- Spotify + browser media reliably appear on the Presonus without manual qpwgraph fiddling on every launch.
- VLC behavior unchanged (HDMI TVs).
- The project copy of the rule + script is the source of truth.

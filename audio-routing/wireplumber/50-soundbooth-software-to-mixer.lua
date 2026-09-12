-- 50-soundbooth-software-to-mixer.lua
--
-- WirePlumber rule (for 0.4.x) to send software audio sources to the "Mixer"
-- virtual sink by default. The Mixer monitor is then routed in qpwgraph
-- (or a fixed link) to the Presonus StudioLive 32SX.
--
-- Policy:
--   Software apps (Spotify, browsers, FreeShow, …) → Mixer → Presonus FOH.
--   Exception: program TV audio (ffplay / ffmpeg display) → LocalLive → HDMI (DP-4).
--   Do not match VLC/ffplay with broad "*player*" patterns.
--
-- Place a copy (or symlink) in:
--   ~/.config/wireplumber/main.lua.d/50-soundbooth-software-to-mixer.lua
--
-- After editing: systemctl --user restart wireplumber

rule = {
  matches = {
    {
      -- Spotify (snap usually appears as "spotify")
      { "application.name", "matches", "spotify" },
      { "media.class", "equals", "Stream/Output/Audio" },
    },
    {
      -- Chromium / Chrome / Vivaldi / Edge based browsers / FreeShow
      { "application.name", "matches", "*hromium*" },
      { "media.class", "equals", "Stream/Output/Audio" },
    },
    {
      { "application.name", "matches", "*vivaldi*" },
      { "media.class", "equals", "Stream/Output/Audio" },
    },
    {
      -- Firefox
      { "application.name", "matches", "*irefox*" },
      { "media.class", "equals", "Stream/Output/Audio" },
    },
    -- NOTE: intentionally no "*player*" catch-all — it matched ffplay and
    -- sent sanctuary program audio to FOH Mixer.
  },
  apply_properties = {
    ["node.target"] = "Mixer",
  },
}

-- Program display (ffplay): route to HDMI TV stereo sink, not Mixer/FOH.
-- Card profile should be output:hdmi-stereo-extra1 (HDMI TV / DP-4).
rule_ffplay_tv = {
  matches = {
    {
      { "application.name", "equals", "ffplay" },
      { "media.class", "equals", "Stream/Output/Audio" },
    },
    {
      { "application.process.binary", "equals", "ffplay" },
      { "media.class", "equals", "Stream/Output/Audio" },
    },
  },
  apply_properties = {
    -- node.name of Digital Stereo (HDMI 2) = HDMI TV on this booth
    ["node.target"] = "alsa_output.pci-0000_07_00.1.hdmi-stereo-extra1",
  },
}

-- Insert into the appropriate rules table.
-- In WirePlumber 0.4 the monitor rules table is commonly alsa_monitor.rules
-- or just rules depending on how the scripts are loaded.
-- If this doesn't take effect, move the logic into a full script in scripts/
-- or use the ensure-audio-routes.sh helper as a fallback.
table.insert(alsa_monitor.rules, rule)
table.insert(alsa_monitor.rules, rule_ffplay_tv)

-- Optional: also try the session rules table if your WP loads it that way
-- table.insert(session.rules or {}, rule)


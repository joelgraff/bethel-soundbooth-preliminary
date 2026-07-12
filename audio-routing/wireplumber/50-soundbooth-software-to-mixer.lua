-- 50-soundbooth-software-to-mixer.lua
--
-- WirePlumber rule (for 0.4.x) to send software audio sources to the "Mixer"
-- virtual sink by default. The Mixer monitor is then routed in qpwgraph
-- (or a fixed link) to the Presonus StudioLive 32SX.
--
-- Policy:
--   Any app that is an audio source → Presonus board (via Mixer).
--   Exception: VLC stays on HDMI for the TVs (we do not match it here).
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
      -- Chromium / Chrome / Vivaldi / Edge based browsers
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
    {
      -- General fallback for other desktop apps (be careful not to catch VLC)
      { "application.name", "matches", "*player*" },
      { "media.class", "equals", "Stream/Output/Audio" },
    },
    -- Add more specific app names here as discovered (FreeShow, etc.)
  },
  apply_properties = {
    -- Route to the "Mixer" virtual sink (node.name from our pulse null-sink)
    -- Adjust if you prefer "System" or the raw Presonus node name.
    ["node.target"] = "Mixer",
    -- You can also use "target.object" in some contexts.
  },
}

-- Insert into the appropriate rules table.
-- In WirePlumber 0.4 the monitor rules table is commonly alsa_monitor.rules
-- or just rules depending on how the scripts are loaded.
-- If this doesn't take effect, move the logic into a full script in scripts/
-- or use the ensure-audio-routes.sh helper as a fallback.
table.insert(alsa_monitor.rules, rule)

-- Optional: also try the session rules table if your WP loads it that way
-- table.insert(session.rules or {}, rule)

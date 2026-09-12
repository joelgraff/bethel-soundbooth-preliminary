-- 52-atem-audio-ignore.lua
--
-- ATEM Mini Extreme's own audio interface (card "Extreme") must stay off
-- PipeWire entirely. Architecture (SYSTEM-STATE.md): ffmpeg-capture.service reads
-- ATEM audio directly via ALSA plughw:Extreme,0 (Pulse/PipeWire capture is
-- unreliable with FFmpeg for this device). Nothing in this system uses the
-- ATEM's audio through PipeWire/Ardour/qpwgraph — unlike the PreSonus card,
-- there is no legitimate PipeWire consumer to protect here.
--
-- Root-caused 2026-08-02: after a reboot, PipeWire's ALSA monitor claimed
-- /dev/snd/pcmC1D0c (the ATEM's capture PCM) before ffmpeg-capture.service could
-- open it, so ffmpeg's direct ALSA open failed with "Device or resource
-- busy" and ffmpeg-capture.service crash-looped forever. device.disabled is safe
-- here (unlike PreSonus, where it was a mistake — see 51-presonus-soft-mixer.lua)
-- because nothing needs this card inside PipeWire.
--
-- Install: ~/.config/wireplumber/main.lua.d/
-- Then: systemctl --user restart wireplumber
--       systemctl --user restart ffmpeg-capture ffmpeg-display

rule_atem_audio_card = {
  matches = {
    {
      { "device.name", "matches", "alsa_card.usb-Blackmagic_Design_ATEM_Mini_Extreme*" },
    },
  },
  apply_properties = {
    ["device.disabled"] = true,
  },
}

table.insert(alsa_monitor.rules, rule_atem_audio_card)

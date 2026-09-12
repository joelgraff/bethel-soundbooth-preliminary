-- 51-presonus-soft-mixer.lua
--
-- PreSonus StudioLive 32SX: full USB is 64ch S32_LE (pro-audio / multichannel).
-- That is normal and required for Ardour multitrack + qpwgraph.
--
-- Problem we hit: ACP "HARDWARE DECIBEL_VOLUME" on the *playback* sink can report
-- channel volumes at 0%/-inf so Mixer→AUX0/1 links look live but FOH is silent.
-- api.alsa.soft-mixer forces software gain so levels can be set.
--
-- Do NOT set device.disabled — that hides the card from PipeWire and blocks
-- Ardour/qpwgraph (2026-08-02 mistake). FOH uses Mixer→playback_AUX0/1 links;
-- exclusive ALSA aplay bridge is fallback only, not default.
--
-- Install: ~/.config/wireplumber/main.lua.d/
-- Then: systemctl --user restart wireplumber
--        systemctl --user stop presonus-foh-bridge.service  # free device if bridge held it
--        ~/bin/ensure-audio-routes.sh

rule_card = {
  matches = {
    {
      { "device.name", "matches", "alsa_card.usb-PreSonus*" },
    },
  },
  apply_properties = {
    ["api.alsa.soft-mixer"] = true,
    ["api.alsa.ignore-dB"] = true,
  },
}

-- Also tag the PCM nodes once created (pro-audio / multichannel)
rule_nodes = {
  matches = {
    {
      { "node.name", "matches", "alsa_output.usb-PreSonus*" },
    },
    {
      { "node.name", "matches", "alsa_input.usb-PreSonus*" },
    },
  },
  apply_properties = {
    ["api.alsa.soft-mixer"] = true,
    ["api.alsa.ignore-dB"] = true,
  },
}

table.insert(alsa_monitor.rules, rule_card)
table.insert(alsa_monitor.rules, rule_nodes)

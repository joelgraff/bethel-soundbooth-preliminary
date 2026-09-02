# AI agent bridge — tool list

Status: design settled, not yet wired to a model. See `dashboard/backend/app/agent_tools.py`
for the scaffolded (but not-yet-model-connected) implementations.

## Why this exists

The boot-time `sunday-grok.service` launches an interactive CLI agent (`grok`) in a
terminal with full shell/file access to the machine — see
`audio-routing/scripts/sunday-grok-session.sh`. That's acceptable when the only way to
reach it is sitting at the booth PC. The dashboard's chat panel needs to be reachable
from the soundbooth LAN subnet as well (password-protected, separate from guest
Wi-Fi — confirmed 2026-09-01), so giving it that same unrestricted shell access would
mean anyone with the dashboard PIN gets arbitrary command execution on a live
production machine from across the building.

Decision: the web-facing agent (engine: Claude, not Grok) gets a **fixed, code-enforced
toolset that mirrors exactly what the dashboard's own buttons can do** — nothing more.
One session (no per-device agent instances). This replaces the terminal-based Sunday
Grok launch as the canonical agent surface once it's built.

## Tool list

Read-only:

| Tool | Does | Notes |
|---|---|---|
| `get_health_status()` | Runs/reads `soundbooth-health.sh --json` | pass/warn/fail counts + individual check results |
| `list_services()` | Status of every unit in `units_manifest.json` | `systemctl --user show <unit>` |
| `get_service_log(unit, lines)` | `journalctl --user -u <unit> -n <lines>` | `unit` must be in the manifest; `lines` capped at 200 |
| `get_output_status(display)` | Signal-present / last-updated for DP-1..4 | metadata only, no video — depends on the HDMI-preview subsystem (not built yet) |
| `read_doc(name)` | One of: `SYSTEM-STATE.md`, `STATUS.md`, `portal/content/quick-reference.md`, `AGENTS.md` | fixed allowlist, not arbitrary file access |

Actions, backed by `units_manifest.json`:

| Tool | Does | Notes |
|---|---|---|
| `restart_service(unit)` | `systemctl --user restart <unit>` | low-stakes, self-healing — executes directly |
| `start_service(unit)` / `stop_service(unit)` | Same, for units meant to be manually toggled | today just `ffmpeg-srt-relay.service` (the livestream leg) |

Explicitly **excluded**, unlike the terminal Grok session: arbitrary shell exec,
arbitrary file read/write, any unit not on the manifest, journalctl beyond allowlisted
units, outbound network calls.

## Confirmation gate

Any action the manifest marks `"confirm"` for (currently: starting or stopping the
livestream relay — see `units_manifest.json`) does not execute on the model's tool
call alone. It stages the action and returns a confirmation token; the frontend
surfaces this as an explicit Yes/No prompt, and the actual execution endpoint
(`confirm.py`) requires that token **and** a fresh click from the operator's own
session. This holds even if the model misjudges a request — nothing that ends a live
broadcast fires without a human confirming in the UI.

## Not yet done

- The actual Claude Agent SDK wiring (registering these tools, streaming the
  conversation to the chat panel over `/ws/agent`) — `agent_tools.py` has the
  functions ready to register but the endpoint is a stub. Needs an API key /
  credential storage decision before it's live.
- Retiring `sunday-grok.service`'s terminal launch once the bridge is trusted.
- The HDMI output-preview subsystem that `get_output_status()` depends on.

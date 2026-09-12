# AI agent bridge — tool list

Status: **wired.** `dashboard/backend/app/agent.py` (`AgentBridge`) runs one
shared Claude session behind `/ws/agent`, streaming to every connected chat
panel. Model defaults to `claude-sonnet-5` (`AGENT_MODEL` in `dashboard.conf`),
run at `effort: low`. Tool functions and their Anthropic schemas are in
`dashboard/backend/app/agent_tools.py` (`build_tool_specs` / `call_tool`).

## Why this exists

A now-retired boot-time service used to launch an interactive CLI agent in a
terminal with full shell/file access to the machine. That was acceptable when the only
way to reach it is sitting at the booth PC. The dashboard's chat panel needs to be
reachable from the soundbooth LAN subnet as well (password-protected, separate from
guest Wi-Fi — confirmed 2026-09-01), so giving it that same unrestricted shell access
would mean anyone with the dashboard PIN gets arbitrary command execution on a live
production machine from across the building.

Decision: the web-facing agent gets a **fixed, code-enforced toolset that mirrors
exactly what the dashboard's own buttons can do** — nothing more. One session (no
per-device agent instances). This is now the canonical agent surface; the old
terminal-based session has been retired.

## Tool list

Read-only:

| Tool | Does | Notes |
|---|---|---|
| `get_health_status()` | Runs/reads `soundbooth-health.sh --json` | pass/warn/fail counts + individual check results |
| `list_services()` | Status of every unit in `units_manifest.json` | `systemctl --user show <unit>` |
| `get_service_log(unit, lines)` | `journalctl --user -u <unit> -n <lines>` | `unit` must be in the manifest; `lines` capped at 200 |
| `get_output_status(display)` | Preview-frame freshness for `DP-2`, `DP-3`, `DP-4`, `LIVESTREAM` | metadata only, no video; DP-1 is deliberately not captured |
| `read_doc(name)` | One of: `SYSTEM-STATE.md`, `STATUS.md`, `quick-reference.md`, `AGENTS.md` | fixed allowlist, not arbitrary file access |

Actions, backed by `units_manifest.json`:

| Tool | Does | Notes |
|---|---|---|
| `restart_service(unit)` | `systemctl --user restart <unit>` | low-stakes, self-healing — executes directly |
| `start_service(unit)` / `stop_service(unit)` | Same, for units meant to be manually toggled | today just `ffmpeg-srt-relay.service` (the livestream leg) |

Explicitly **excluded**, unlike the old terminal session: arbitrary shell exec,
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

## How the model runs

Official `anthropic` Python SDK, `AsyncAnthropic`, **manual streaming loop** in
`AgentBridge._run_turn` (not the beta tool runner — the loop needs to
intercept a confirm-gated tool result before it reaches the model and turn it
into an operator prompt). One `AgentBridge` per process; `_turn_lock`
serialises turns; events are broadcast to every connected socket. History is
trimmed to the last ~40 messages, never below a valid user-first prefix.

`run_calibration` is intentionally **not** in the model's toolset — it juggles
the shared `:5002` UDP port and belongs to its own dashboard card, not a chat
turn.

## Not yet done

- A "New chat" control in the panel (the `reset` message type is handled
  backend-side already).
- Persisting the conversation across a dashboard restart (currently in-memory
  only).

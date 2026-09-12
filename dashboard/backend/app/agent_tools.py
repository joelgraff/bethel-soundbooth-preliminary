"""The agent bridge's tool functions — see dashboard/docs/agent-tools.md.

These are plain functions, deliberately not yet wired to a model. When the
Claude Agent SDK integration is built, each of these gets registered as a
tool; until then this module exists so the *authority boundary* (what the
agent may touch) is decided and testable independently of picking an SDK,
an API key, and a streaming transport.

Every action tool routes through units.check_action_allowed() and, for
anything the manifest marks "confirm", through confirm.ConfirmStore — the
same two gates the REST endpoints use. There is no separate, wider path for
the agent to reach systemctl.
"""
from __future__ import annotations

import time
from pathlib import Path
from typing import TYPE_CHECKING

from . import calibrate as calibrate_mod
from . import health as health_mod
from . import systemctl_client
from . import units as units_mod
from .confirm import confirm_store

if TYPE_CHECKING:
    from .config import Settings

# Which HDMI output maps to which preview-capture output file. DP-1 is
# deliberately not captured — see dashboard/README.md.
PREVIEW_FILES = {
    "DP-2": "dp2.jpg",
    "DP-3": "dp3.jpg",
    "DP-4": "dp4.jpg",
    # Not a real xrandr connector — the SRT-relay-bound encode leg (see
    # start-hdmi-preview-livestream.sh). get_output_status() below only ever
    # does a file mtime check, never touches xrandr, so a non-connector key
    # works the same as a real one.
    "LIVESTREAM": "livestream.jpg",
}

# Which systemd unit is responsible for keeping each preview file fresh —
# used to tell "genuinely broken" (capture service not running) apart from
# "no new frame because nothing on screen changed". DP-2/DP-3 in particular
# use Mutter's damage-based ScreenCast capture: it only emits a frame when
# the screen's pixels actually change, so a static slide sitting on screen
# for minutes produces no new frames and is completely normal, not broken.
# Before this, get_output_status() only checked frame age, which flagged
# every long-static slide as "unavailable" even though the capture pipeline
# was fine — see STATUS.md 2026-09-04.
PREVIEW_SERVICES = {
    "DP-2": "hdmi-preview.service",
    "DP-3": "hdmi-preview.service",
    "DP-4": "hdmi-preview-dp4.service",
    "LIVESTREAM": "hdmi-preview-livestream.service",
}

# Fixed allowlist for read_doc — not arbitrary filesystem access.
_READABLE_DOCS = {
    "SYSTEM-STATE.md": "SYSTEM-STATE.md",
    "STATUS.md": "STATUS.md",
    "AGENTS.md": "AGENTS.md",
    "quick-reference.md": "portal/content/quick-reference.md",
}

MAX_LOG_LINES = 200


class AgentToolError(RuntimeError):
    pass


def get_health_status(*, health_script: Path) -> dict:
    return health_mod.get_health_status(health_script)


def list_services(*, manifest_path: Path) -> list[dict]:
    entries = units_mod.load_units(manifest_path)
    out = []
    for entry in entries.values():
        status = systemctl_client.get_status(entry.unit)
        out.append(
            {
                "unit": entry.unit,
                "display_name": entry.display_name,
                "group": entry.group_label,
                "actions": list(entry.actions),
                **status,
            }
        )
    return out


def get_service_log(*, manifest_path: Path, unit: str, lines: int = 50) -> list[str]:
    units = units_mod.load_units(manifest_path)
    if unit not in units:
        raise AgentToolError(f"{unit!r} is not on the dashboard's unit manifest")
    return systemctl_client.tail_journal(unit, min(int(lines), MAX_LOG_LINES))


def get_output_status(*, display: str, preview_dir: Path, max_age_sec: int) -> dict:
    filename = PREVIEW_FILES.get(display)
    if filename is None:
        return {
            "display": display,
            "available": False,
            "reason": "not captured (see dashboard/README.md)",
        }
    frame_path = preview_dir / filename
    if not frame_path.is_file():
        return {"display": display, "available": False, "reason": "no frame captured yet"}
    age = time.time() - frame_path.stat().st_mtime

    service = PREVIEW_SERVICES.get(display)
    if service:
        try:
            service_active = systemctl_client.get_status(service)["active_state"] == "active"
        except systemctl_client.SystemctlError:
            service_active = False
        if service_active:
            # Capture pipeline is alive — hold the last frame indefinitely,
            # however old, rather than flagging normal static content as
            # broken (see PREVIEW_SERVICES comment above).
            return {"display": display, "available": True, "age_sec": round(age, 1)}
        return {
            "display": display,
            "available": False,
            "reason": f"{service} not running — last frame {age:.0f}s ago",
        }

    # No known capture service for this display (shouldn't happen for any
    # current PREVIEW_FILES entry) — fall back to a plain age check.
    if age > max_age_sec:
        return {
            "display": display,
            "available": False,
            "reason": f"stale — last frame {age:.0f}s ago",
        }
    return {"display": display, "available": True, "age_sec": round(age, 1)}


def read_doc(*, project_dir: Path, name: str) -> str:
    rel = _READABLE_DOCS.get(name)
    if rel is None:
        raise AgentToolError(
            f"{name!r} is not readable by the agent "
            f"(allowed: {sorted(_READABLE_DOCS)})"
        )
    path = project_dir / rel
    if not path.is_file():
        raise AgentToolError(f"{rel} not found under {project_dir}")
    return path.read_text()


def restart_service(*, manifest_path: Path, unit: str) -> dict:
    units = units_mod.load_units(manifest_path)
    units_mod.check_action_allowed(units, unit, "restart")
    systemctl_client.run_action(unit, "restart")
    return systemctl_client.get_status(unit)


def _start_or_stop(*, manifest_path: Path, unit: str, action: str, confirm_token: str | None) -> dict:
    units = units_mod.load_units(manifest_path)
    entry = units_mod.check_action_allowed(units, unit, action)

    confirm_message = entry.confirm.get(action)
    if confirm_message:
        if not confirm_token:
            token = confirm_store.stage(unit, action, confirm_message)
            return {
                "requires_confirmation": True,
                "message": confirm_message,
                "confirm_token": token,
            }
        if not confirm_store.redeem(confirm_token, unit, action):
            raise AgentToolError(
                "confirmation token missing, already used, or expired — ask the "
                "operator to confirm again"
            )

    systemctl_client.run_action(unit, action)
    return {"requires_confirmation": False, **systemctl_client.get_status(unit)}


def start_service(*, manifest_path: Path, unit: str, confirm_token: str | None = None) -> dict:
    return _start_or_stop(
        manifest_path=manifest_path, unit=unit, action="start", confirm_token=confirm_token
    )


def stop_service(*, manifest_path: Path, unit: str, confirm_token: str | None = None) -> dict:
    return _start_or_stop(
        manifest_path=manifest_path, unit=unit, action="stop", confirm_token=confirm_token
    )


def run_calibration(*, calibrate_script: Path, duration: float = calibrate_mod.DEFAULT_DURATION) -> dict:
    """Measures A/V sync via av-sync-calibrate.py capture-udp. Read-only in
    the sense that it never writes the suggested delay into the live config
    or restarts the program encode — that's a separate, more consequential
    action (--apply-restart) deliberately not wired up here; the operator
    applies it by hand for now."""
    return calibrate_mod.run_calibration(script_path=calibrate_script, duration=duration)


# ---------------------------------------------------------------------------
# Model-facing tool surface — the agent bridge (app/agent.py) registers these
# with the Anthropic API. Each name maps 1:1 to a function above, and every
# unit/action still passes through units.check_action_allowed() +
# confirm_store, so this list can't widen what the agent may touch beyond
# what units_manifest.json and the REST endpoints already allow. Deliberately
# NOT exposed: run_calibration (it moves a shared UDP port around and the
# operator runs it from its own card) and any confirm_token plumbing — the
# agent can only *stage* a confirm-gated action, never complete one.
# ---------------------------------------------------------------------------

_OUTPUT_DISPLAYS = sorted(PREVIEW_FILES)  # DP-2, DP-3, DP-4, LIVESTREAM


def build_tool_specs(manifest_path: Path) -> list[dict]:
    """Anthropic tool definitions, with unit names enumerated straight from
    the manifest so the model gets a 400-free schema and can't invent a unit.
    Sorted for a stable (cache-friendly) prompt prefix."""
    units = units_mod.load_units(manifest_path)
    all_units = sorted(units)
    restartable = sorted(u for u, e in units.items() if "restart" in e.actions)
    startable = sorted(u for u, e in units.items() if "start" in e.actions)
    stoppable = sorted(u for u, e in units.items() if "stop" in e.actions)

    return [
        {
            "name": "get_health_status",
            "description": (
                "Run the soundbooth health check and return pass/warn/fail "
                "counts plus each individual check result. Start here when "
                "asked 'is anything wrong'."
            ),
            "input_schema": {"type": "object", "properties": {}, "additionalProperties": False},
        },
        {
            "name": "list_services",
            "description": (
                "Current active/sub state of every systemd --user unit the "
                "dashboard manages, grouped as on the dashboard."
            ),
            "input_schema": {"type": "object", "properties": {}, "additionalProperties": False},
        },
        {
            "name": "get_service_log",
            "description": "Tail the journal for one managed unit.",
            "input_schema": {
                "type": "object",
                "properties": {
                    "unit": {"type": "string", "enum": all_units},
                    "lines": {
                        "type": "integer",
                        "minimum": 1,
                        "maximum": MAX_LOG_LINES,
                        "description": f"How many lines (default 50, max {MAX_LOG_LINES}).",
                    },
                },
                "required": ["unit"],
                "additionalProperties": False,
            },
        },
        {
            "name": "get_output_status",
            "description": (
                "Whether a video output currently has a fresh preview frame. "
                "Metadata only — no image. LIVESTREAM is the encode leg sent "
                "to Subsplash, not a physical connector."
            ),
            "input_schema": {
                "type": "object",
                "properties": {"display": {"type": "string", "enum": _OUTPUT_DISPLAYS}},
                "required": ["display"],
                "additionalProperties": False,
            },
        },
        {
            "name": "read_doc",
            "description": (
                "Read one project reference doc for context on how the booth "
                "is meant to be set up."
            ),
            "input_schema": {
                "type": "object",
                "properties": {"name": {"type": "string", "enum": sorted(_READABLE_DOCS)}},
                "required": ["name"],
                "additionalProperties": False,
            },
        },
        {
            "name": "restart_service",
            "description": (
                "Restart one managed unit. Low-stakes and self-healing — runs "
                "immediately, no confirmation. Use for a frozen/stuck service."
            ),
            "input_schema": {
                "type": "object",
                "properties": {"unit": {"type": "string", "enum": restartable}},
                "required": ["unit"],
                "additionalProperties": False,
            },
        },
        {
            "name": "start_service",
            "description": (
                "Start one manually-toggled unit. If it is confirm-gated (the "
                "livestream relay is), this only STAGES the action and shows "
                "the operator a Yes/No prompt in the dashboard — you cannot "
                "complete it yourself; tell the operator to click to confirm."
            ),
            "input_schema": {
                "type": "object",
                "properties": {"unit": {"type": "string", "enum": startable}},
                "required": ["unit"],
                "additionalProperties": False,
            },
        },
        {
            "name": "stop_service",
            "description": (
                "Stop one manually-toggled unit. Same confirm-gating as "
                "start_service — stopping the livestream relay ends the live "
                "broadcast, so it only stages and waits for the operator."
            ),
            "input_schema": {
                "type": "object",
                "properties": {"unit": {"type": "string", "enum": stoppable}},
                "required": ["unit"],
                "additionalProperties": False,
            },
        },
    ]


def call_tool(name: str, tool_input: dict, *, settings: "Settings") -> object:
    """Dispatch one model tool call to the function above. Raises
    AgentToolError / UnknownUnitError / ActionNotAllowedError / SystemctlError
    on bad input or a failed action — the caller turns those into an
    is_error tool result. Return value is always JSON-serialisable.

    start_service / stop_service are always called with confirm_token=None:
    the agent can stage a confirm-gated action but never redeem the token —
    that stays a human click in the operator's own session (see
    dashboard/docs/agent-tools.md)."""
    manifest = settings.manifest_path
    tool_input = tool_input or {}

    if name == "get_health_status":
        return get_health_status(health_script=settings.health_script)
    if name == "list_services":
        return list_services(manifest_path=manifest)
    if name == "get_service_log":
        return get_service_log(
            manifest_path=manifest,
            unit=tool_input["unit"],
            lines=int(tool_input.get("lines", 50)),
        )
    if name == "get_output_status":
        return get_output_status(
            display=tool_input["display"],
            preview_dir=settings.preview_dir,
            max_age_sec=settings.preview_frame_max_age_sec,
        )
    if name == "read_doc":
        return read_doc(project_dir=settings.project_dir, name=tool_input["name"])
    if name == "restart_service":
        return restart_service(manifest_path=manifest, unit=tool_input["unit"])
    if name == "start_service":
        return start_service(manifest_path=manifest, unit=tool_input["unit"], confirm_token=None)
    if name == "stop_service":
        return stop_service(manifest_path=manifest, unit=tool_input["unit"], confirm_token=None)

    raise AgentToolError(f"unknown tool {name!r}")

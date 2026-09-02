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

from . import calibrate as calibrate_mod
from . import health as health_mod
from . import systemctl_client
from . import units as units_mod
from .confirm import confirm_store

# Which HDMI output maps to which preview-capture output file. DP-1 is
# deliberately not captured — see dashboard/README.md.
PREVIEW_FILES = {
    "DP-2": "dp2.jpg",
    "DP-3": "dp3.jpg",
    "DP-4": "dp4.jpg",
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

"""Loads units_manifest.json — the single allowlist shared by the REST API
and the agent tools. Nothing outside this file's data is a valid target for
a systemctl action anywhere in the dashboard.
"""
from __future__ import annotations

import json
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path


@dataclass(frozen=True)
class UnitEntry:
    unit: str
    display_name: str
    group_id: str
    group_label: str
    actions: tuple[str, ...]
    confirm: dict[str, str]


class UnknownUnitError(ValueError):
    pass


class ActionNotAllowedError(ValueError):
    pass


@lru_cache(maxsize=1)
def _raw_manifest(manifest_path: str) -> dict:
    with open(manifest_path) as f:
        return json.load(f)


def load_units(manifest_path: Path) -> dict[str, UnitEntry]:
    raw = _raw_manifest(str(manifest_path))
    units: dict[str, UnitEntry] = {}
    for group in raw["groups"]:
        for entry in group["units"]:
            units[entry["unit"]] = UnitEntry(
                unit=entry["unit"],
                display_name=entry["display_name"],
                group_id=group["id"],
                group_label=group["label"],
                actions=tuple(entry.get("actions", [])),
                confirm=entry.get("confirm", {}),
            )
    return units


def load_groups(manifest_path: Path) -> list[dict]:
    return _raw_manifest(str(manifest_path))["groups"]


def load_quick_actions(manifest_path: Path) -> list[dict]:
    return _raw_manifest(str(manifest_path)).get("quick_actions", [])


def check_action_allowed(
    units: dict[str, UnitEntry], unit: str, action: str
) -> UnitEntry:
    """Raise if `unit`/`action` isn't on the manifest. Call this before every
    systemctl call anywhere in the backend or the agent tools — it's the only
    thing standing between a request and touching a live production service.
    """
    entry = units.get(unit)
    if entry is None:
        raise UnknownUnitError(f"{unit!r} is not on the dashboard's unit manifest")
    if action not in entry.actions:
        raise ActionNotAllowedError(
            f"{action!r} is not an allowed action for {unit!r} "
            f"(allowed: {entry.actions})"
        )
    return entry

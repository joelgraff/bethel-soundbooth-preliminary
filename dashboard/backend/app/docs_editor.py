"""Reference-doc viewer/editor for the dashboard's Docs page.

Read AND write, unlike agent_tools.read_doc (agent-facing, read-only, its own
smaller allowlist for chat context) — this is the human-facing "look at and
update the equipment/connections catalog" surface requested alongside
docs/equipment-and-connections.md. Fixed allowlist, not arbitrary filesystem
access, same principle as every other write path in this dashboard
(units_manifest.json for services, resolve_recording_path for recordings).

Writes go straight to the file in the project's git working tree — the same
place a Claude Code session editing this repo would write. Deliberately NOT
auto-committed: committing stays a deliberate, reviewed, separate step (see
dashboard/README.md), so a save from this page is a working-tree edit until
someone runs `git commit` on it, same as any other uncommitted change in this
repo.
"""
from __future__ import annotations

from pathlib import Path
from typing import Optional

# doc_id -> {title, path (relative to project_dir)}. Deliberately narrow: this
# is the "physical reference docs" surface, not a general file editor. Extend
# by adding an entry here, not by accepting arbitrary paths from the client.
_EDITABLE_DOCS: dict[str, dict[str, str]] = {
    "equipment": {
        "title": "Equipment & Connections",
        "path": "docs/equipment-and-connections.md",
    },
    "mixer-map": {
        "title": "Mixer Channel Map",
        "path": "docs/mixer-channel-map.md",
    },
    # YAML rather than markdown: the Docs page renders this one as diagrams
    # (see signal_chain.py) instead of prose, but editing is the same raw-text
    # flow as any other doc here.
    "signal-chain": {
        "title": "Signal Chain (diagram)",
        "path": "docs/signal-chain.yaml",
        "kind": "signal-chain",
    },
}


class DocsError(RuntimeError):
    pass


class DocsConflictError(DocsError):
    """Raised when a save's expected_mtime no longer matches the file on
    disk — someone else (another browser tab, or a Claude Code session
    working on this same repo) changed it since this client last loaded it."""


def _meta(doc_id: str) -> dict[str, str]:
    meta = _EDITABLE_DOCS.get(doc_id)
    if meta is None:
        raise DocsError(f"{doc_id!r} is not an editable doc (allowed: {sorted(_EDITABLE_DOCS)})")
    return meta


def list_docs(*, project_dir: Path) -> list[dict]:
    out = []
    for doc_id, meta in _EDITABLE_DOCS.items():
        path = project_dir / meta["path"]
        exists = path.is_file()
        out.append({
            "id": doc_id,
            "title": meta["title"],
            "path": meta["path"],
            "kind": meta.get("kind", "markdown"),
            "exists": exists,
            "mtime": path.stat().st_mtime if exists else None,
        })
    return out


def read_doc(*, project_dir: Path, doc_id: str) -> dict:
    meta = _meta(doc_id)
    path = project_dir / meta["path"]
    kind = meta.get("kind", "markdown")
    if not path.is_file():
        return {
            "id": doc_id, "title": meta["title"], "path": meta["path"], "kind": kind,
            "exists": False, "content": "", "mtime": None,
        }
    return {
        "id": doc_id, "title": meta["title"], "path": meta["path"], "kind": kind,
        "exists": True, "content": path.read_text(), "mtime": path.stat().st_mtime,
    }


def write_doc(
    *, project_dir: Path, doc_id: str, content: str, expected_mtime: Optional[float] = None
) -> dict:
    meta = _meta(doc_id)
    path = project_dir / meta["path"]

    if expected_mtime is not None and path.is_file():
        actual = path.stat().st_mtime
        # Small tolerance for filesystem mtime granularity, not a real check
        # of "did anything change" — just avoids false conflicts from float
        # rounding on some filesystems.
        if abs(actual - expected_mtime) > 0.5:
            raise DocsConflictError(
                f"{meta['path']} changed on disk since you loaded it "
                "(someone else saved it, or a Claude Code session edited the repo) — "
                "reload before saving so you don't overwrite the newer version."
            )

    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)
    return {"id": doc_id, "path": meta["path"], "mtime": path.stat().st_mtime}

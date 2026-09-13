"""Config loading for the soundbooth dashboard.

Follows the same KEY=VALUE conf-file convention used elsewhere in this project
(ffmpeg-srt.conf) so it's editable the same way, even though this consumer is
Python rather than bash.
"""
from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

DEFAULT_CONF_PATH = Path(
    os.environ.get(
        "SOUNDBOOTH_DASHBOARD_CONF",
        str(Path.home() / ".config" / "soundbooth" / "dashboard.conf"),
    )
)


def _parse_conf(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.is_file():
        return values
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        values[key.strip()] = value.strip().strip('"').strip("'")
    return values


@dataclass(frozen=True)
class Settings:
    pin: str
    local_token: str
    session_secret: str
    host: str
    port: int
    project_dir: Path
    health_script: Path
    manifest_path: Path
    calibrate_script: Path
    preview_dir: Path
    preview_frame_max_age_sec: int
    recordings_dir: Path
    recording_max_duration_sec: float
    livestream_schedule_script: Path
    anthropic_api_key: str
    agent_model: str


def load_settings() -> Settings:
    conf = _parse_conf(DEFAULT_CONF_PATH)
    project_dir = Path(
        conf.get("PROJECT_DIR", str(Path.home() / "soundbooth-project"))
    )
    return Settings(
        pin=conf.get("DASHBOARD_PIN", ""),
        local_token=conf.get("LOCAL_TOKEN", ""),
        session_secret=conf.get("SESSION_SECRET", ""),
        host=conf.get("DASHBOARD_HOST", "127.0.0.1"),
        port=int(conf.get("DASHBOARD_PORT", "8420")),
        project_dir=project_dir,
        health_script=Path(
            conf.get(
                "HEALTH_SCRIPT", str(Path.home() / "bin" / "soundbooth-health.sh")
            )
        ),
        manifest_path=Path(__file__).parent / "units_manifest.json",
        calibrate_script=Path(
            conf.get(
                "CALIBRATE_SCRIPT", str(Path.home() / "bin" / "av-sync-calibrate.py")
            )
        ),
        preview_dir=Path(
            conf.get("HDMI_PREVIEW_DIR", "/dev/shm/soundbooth-dashboard")
        ),
        preview_frame_max_age_sec=int(conf.get("HDMI_PREVIEW_MAX_AGE_SEC", "10")),
        recordings_dir=Path(
            conf.get("RECORDINGS_DIR", str(Path.home() / "Recordings"))
        ),
        recording_max_duration_sec=float(
            conf.get("RECORDING_MAX_DURATION_SEC", str(6 * 3600))
        ),
        livestream_schedule_script=Path(
            conf.get(
                "LIVESTREAM_SCHEDULE_SCRIPT",
                str(Path.home() / "bin" / "livestream-schedule.sh"),
            )
        ),
        # The agent bridge (dashboard/backend/app/agent.py) reads this. An
        # env ANTHROPIC_API_KEY wins if the conf key is unset/placeholder, so
        # the SDK's own resolution still works in dev. "changeme" (the
        # value shipped in dashboard.conf.example) counts as unset.
        anthropic_api_key=(
            conf.get("ANTHROPIC_API_KEY", "").strip()
            if conf.get("ANTHROPIC_API_KEY", "").strip() not in ("", "changeme")
            else os.environ.get("ANTHROPIC_API_KEY", "")
        ),
        agent_model=conf.get("AGENT_MODEL", "claude-sonnet-5"),
    )

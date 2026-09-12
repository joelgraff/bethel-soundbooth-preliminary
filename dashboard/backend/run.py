"""Entrypoint that binds uvicorn to the host/port from dashboard.conf,
instead of hardcoding them into the systemd unit's ExecStart.
"""
from __future__ import annotations

import uvicorn

from app.config import load_settings


def main() -> None:
    settings = load_settings()
    uvicorn.run("app.main:app", host=settings.host, port=settings.port)


if __name__ == "__main__":
    main()

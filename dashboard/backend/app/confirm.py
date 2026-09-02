"""Confirm-token flow for destructive actions (units_manifest.json's
"confirm" entries — today, starting or stopping the livestream relay).

An action requiring confirmation is never executed on the strength of a
single request — REST or agent tool call alike. The first call stages it and
returns a token; a second, explicit call (a real click in the UI) must
present that same token before anything runs. Tokens are single-use and
expire quickly so a stale confirmation can't fire later by accident.
"""
from __future__ import annotations

import secrets
import time
from dataclasses import dataclass

TOKEN_TTL_SECONDS = 60


@dataclass
class PendingAction:
    unit: str
    action: str
    message: str
    expires_at: float


class ConfirmStore:
    def __init__(self) -> None:
        self._pending: dict[str, PendingAction] = {}

    def stage(self, unit: str, action: str, message: str) -> str:
        token = secrets.token_urlsafe(16)
        self._pending[token] = PendingAction(
            unit=unit,
            action=action,
            message=message,
            expires_at=time.monotonic() + TOKEN_TTL_SECONDS,
        )
        return token

    def redeem(self, token: str, unit: str, action: str) -> bool:
        """Single-use: valid tokens are consumed whether or not they match,
        so a leaked/guessed token can't be replayed against a different
        unit/action either."""
        pending = self._pending.pop(token, None)
        if pending is None:
            return False
        if time.monotonic() > pending.expires_at:
            return False
        return pending.unit == unit and pending.action == action


# One store per process — fine for a single-instance dashboard backend.
confirm_store = ConfirmStore()

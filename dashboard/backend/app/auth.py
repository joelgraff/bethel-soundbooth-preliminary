"""PIN-gated session auth. Deliberately simple: this protects a control
panel reachable on an isolated, password-protected staff LAN subnet, not a
public service — one shared PIN plus a signed session cookie, no accounts.

Also: a local-only bypass token for the booth PC's own dashboard-viewer
window (see start-booth-dashboard-view.sh). Deliberately NOT based on
source IP — testing on the real machine showed at least one local browser
context's requests arrive with the machine's LAN IP rather than 127.0.0.1
(cause unresolved; no proxy configured), so an IP check would be unreliable
here. The token is exactly as strong as the session secret (same conf file,
same trust tier) and is exchanged for a normal session once, on load — see
POST /api/login/local and static/js/api.js's bootstrapLocalToken().
"""
from __future__ import annotations

import hmac

from fastapi import HTTPException, Request


def check_pin(configured_pin: str, submitted_pin: str) -> bool:
    if not configured_pin:
        # Refuse to "helpfully" accept anything if the operator never set a
        # PIN in dashboard.conf — fail closed, not open.
        return False
    return hmac.compare_digest(configured_pin, submitted_pin)


def check_local_token(configured_token: str, submitted_token: str) -> bool:
    if not configured_token or not submitted_token:
        return False
    return hmac.compare_digest(configured_token, submitted_token)


def require_session(request: Request) -> None:
    if not request.session.get("authenticated"):
        raise HTTPException(status_code=401, detail="not authenticated")

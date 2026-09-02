"""Soundbooth dashboard backend — FastAPI app.

Run with: uvicorn app.main:app --host <host> --port <port>
(the soundbooth-dashboard.service unit in dashboard/systemd/ does this).

Scope of this pass: PIN auth, health/services/logs (read), restart/start/stop
(write, allowlisted + confirm-gated). The chat panel's actual model call is
NOT wired up yet — /ws/agent exists as a stub so the frontend has something
to connect to; see dashboard/docs/agent-tools.md for what's left.
"""
from __future__ import annotations

from pathlib import Path
from typing import Optional

from fastapi import Depends, FastAPI, HTTPException, Request, WebSocket
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel
from starlette.middleware.sessions import SessionMiddleware

from . import agent_tools
from .auth import check_local_token, check_pin, require_session
from .calibrate import CalibrationError
from .config import load_settings
from .health import HealthCheckError
from .systemctl_client import SystemctlError
from .units import ActionNotAllowedError, UnknownUnitError, load_groups, load_quick_actions

settings = load_settings()

app = FastAPI(title="Soundbooth Dashboard")
app.add_middleware(SessionMiddleware, secret_key=settings.session_secret or "dev-only-insecure-secret")


class LoginBody(BaseModel):
    pin: str


class LocalLoginBody(BaseModel):
    token: str


class ConfirmableActionBody(BaseModel):
    confirm_token: Optional[str] = None


@app.post("/api/login")
def login(body: LoginBody, request: Request):
    if not check_pin(settings.pin, body.pin):
        raise HTTPException(status_code=401, detail="incorrect PIN")
    request.session["authenticated"] = True
    return {"ok": True}


@app.post("/api/login/local")
def login_local(body: LocalLoginBody, request: Request):
    # Bootstrap for the booth PC's own dashboard-viewer window only — see
    # auth.py's module docstring for why this isn't an IP check.
    if not check_local_token(settings.local_token, body.token):
        raise HTTPException(status_code=401, detail="invalid local token")
    request.session["authenticated"] = True
    return {"ok": True}


@app.post("/api/logout")
def logout(request: Request):
    request.session.clear()
    return {"ok": True}


@app.get("/api/session")
def api_session(request: Request):
    # Deliberately public (no require_session) — this is how the frontend
    # asks "am I logged in?" without tripping the same 401-redirect the
    # other /api/* routes use.
    return {"authenticated": bool(request.session.get("authenticated"))}


@app.get("/api/health")
def api_health(_: None = Depends(require_session)):
    try:
        return agent_tools.get_health_status(health_script=settings.health_script)
    except HealthCheckError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc


@app.get("/api/services")
def api_services(_: None = Depends(require_session)):
    return {
        "groups": load_groups(settings.manifest_path),
        "quick_actions": load_quick_actions(settings.manifest_path),
        "services": agent_tools.list_services(manifest_path=settings.manifest_path),
    }


@app.get("/api/services/{unit}/logs")
def api_service_logs(unit: str, lines: int = 50, _: None = Depends(require_session)):
    try:
        return {"unit": unit, "lines": agent_tools.get_service_log(
            manifest_path=settings.manifest_path, unit=unit, lines=lines
        )}
    except agent_tools.AgentToolError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    except SystemctlError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc


@app.post("/api/services/{unit}/restart")
def api_restart(unit: str, _: None = Depends(require_session)):
    try:
        return agent_tools.restart_service(manifest_path=settings.manifest_path, unit=unit)
    except (UnknownUnitError, ActionNotAllowedError) as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except SystemctlError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc


def _handle_start_stop(unit: str, action: str, body: ConfirmableActionBody):
    fn = agent_tools.start_service if action == "start" else agent_tools.stop_service
    try:
        return fn(manifest_path=settings.manifest_path, unit=unit, confirm_token=body.confirm_token)
    except (UnknownUnitError, ActionNotAllowedError) as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except agent_tools.AgentToolError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    except SystemctlError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc


@app.post("/api/services/{unit}/start")
def api_start(unit: str, body: ConfirmableActionBody, _: None = Depends(require_session)):
    return _handle_start_stop(unit, "start", body)


@app.post("/api/services/{unit}/stop")
def api_stop(unit: str, body: ConfirmableActionBody, _: None = Depends(require_session)):
    return _handle_start_stop(unit, "stop", body)


@app.get("/api/outputs/{display}")
def api_output_status(display: str, _: None = Depends(require_session)):
    return agent_tools.get_output_status(
        display=display,
        preview_dir=settings.preview_dir,
        max_age_sec=settings.preview_frame_max_age_sec,
    )


@app.get("/api/outputs/{display}/frame.jpg")
def api_output_frame(display: str, _: None = Depends(require_session)):
    status = agent_tools.get_output_status(
        display=display,
        preview_dir=settings.preview_dir,
        max_age_sec=settings.preview_frame_max_age_sec,
    )
    if not status["available"]:
        raise HTTPException(status_code=404, detail=status["reason"])
    filename = agent_tools.PREVIEW_FILES[display]
    return FileResponse(
        settings.preview_dir / filename,
        media_type="image/jpeg",
        headers={"Cache-Control": "no-store"},
    )


class CalibrateBody(BaseModel):
    duration: Optional[float] = None


@app.post("/api/calibrate")
def api_calibrate(body: CalibrateBody, _: None = Depends(require_session)):
    kwargs = {"calibrate_script": settings.calibrate_script}
    if body.duration is not None:
        kwargs["duration"] = body.duration
    try:
        return agent_tools.run_calibration(**kwargs)
    except CalibrationError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc


@app.websocket("/ws/agent")
async def ws_agent(websocket: WebSocket):
    if not websocket.session.get("authenticated"):
        await websocket.close(code=4401)
        return
    await websocket.accept()
    await websocket.send_json(
        {
            "role": "system",
            "text": "The AI agent bridge isn't wired up yet — see "
            "dashboard/docs/agent-tools.md for what's left.",
        }
    )
    await websocket.close(code=4501)


# Mounted last and at "/" so it never shadows the /api or /ws routes above —
# FastAPI/Starlette match routes in registration order, and every explicit
# route was already registered by the time this catch-all mount is added.
# html=True serves static/index.html for "/" and lets a bare "/service.html"
# path resolve without the extension too.
_static_dir = Path(__file__).parent.parent / "static"
app.mount("/", StaticFiles(directory=_static_dir, html=True), name="static")

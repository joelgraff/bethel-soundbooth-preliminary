"""Soundbooth dashboard backend — FastAPI app.

Run with: uvicorn app.main:app --host <host> --port <port>
(the soundbooth-dashboard.service unit in dashboard/systemd/ does this).

Scope: PIN auth, health/services/logs (read), restart/start/stop (write,
allowlisted + confirm-gated), board recording, livestream schedule, and the
/ws/agent chat bridge (agent.py) — a real AsyncAnthropic streaming session,
not a stub. See dashboard/docs/agent-tools.md for the agent's tool surface
and security model.
"""
from __future__ import annotations

from pathlib import Path
from typing import Optional

from fastapi import Depends, FastAPI, HTTPException, Request, WebSocket, WebSocketDisconnect
from fastapi.responses import FileResponse, Response
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel
from starlette.middleware.sessions import SessionMiddleware

from . import agent_tools
from . import docs_editor
from . import signal_chain as signal_chain_mod
from . import livestream_schedule as schedule_mod
from . import recording as recording_mod
from .agent import AgentBridge
from .auth import check_local_token, check_pin, require_session
from .calibrate import CalibrationError
from .config import load_settings
from .health import HealthCheckError
from .systemctl_client import SystemctlError
from .units import ActionNotAllowedError, UnknownUnitError, load_groups, load_quick_actions

settings = load_settings()

app = FastAPI(title="Soundbooth Dashboard")
app.add_middleware(SessionMiddleware, secret_key=settings.session_secret or "dev-only-insecure-secret")

# One agent session for the whole dashboard — every chat panel shares it (see
# dashboard/docs/agent-tools.md).
agent_bridge = AgentBridge(settings)


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


class RecordingStartBody(BaseModel):
    channels: list[int]
    name: Optional[str] = None
    split: bool = False


@app.get("/api/recording/status")
def api_recording_status(_: None = Depends(require_session)):
    return recording_mod.get_status()


@app.post("/api/recording/start")
def api_recording_start(body: RecordingStartBody, _: None = Depends(require_session)):
    try:
        return recording_mod.start_recording(
            channels=body.channels,
            name=body.name,
            out_dir=settings.recordings_dir,
            split=body.split,
            max_duration_sec=settings.recording_max_duration_sec,
        )
    except recording_mod.RecordingError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc


@app.post("/api/recording/stop")
def api_recording_stop(_: None = Depends(require_session)):
    try:
        return recording_mod.stop_recording()
    except recording_mod.RecordingError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc


@app.get("/api/recording/list")
def api_recording_list(_: None = Depends(require_session)):
    return {"recordings": recording_mod.list_recordings(out_dir=settings.recordings_dir)}


@app.get("/api/recording/download/{filename}")
def api_recording_download(filename: str, _: None = Depends(require_session)):
    try:
        path = recording_mod.resolve_recording_path(out_dir=settings.recordings_dir, filename=filename)
    except recording_mod.RecordingError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    return FileResponse(path, media_type="audio/wav", filename=path.name)


class ScheduleSetBody(BaseModel):
    schedule: str


class ScheduleArmBody(BaseModel):
    armed: bool


@app.get("/api/livestream/schedule")
def api_schedule_get(_: None = Depends(require_session)):
    return schedule_mod.get_schedule()


@app.post("/api/livestream/schedule")
def api_schedule_set(body: ScheduleSetBody, _: None = Depends(require_session)):
    try:
        return schedule_mod.set_schedule(
            spec=body.schedule, script=settings.livestream_schedule_script
        )
    except schedule_mod.ScheduleError as exc:
        # 400: an invalid calendar spec is bad input, not a conflicting state.
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@app.post("/api/livestream/schedule/arm")
def api_schedule_arm(body: ScheduleArmBody, _: None = Depends(require_session)):
    try:
        return schedule_mod.set_armed(
            armed=body.armed, script=settings.livestream_schedule_script
        )
    except schedule_mod.ScheduleError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc


class DocSaveBody(BaseModel):
    content: str
    expected_mtime: Optional[float] = None


@app.get("/api/docs")
def api_docs_list(_: None = Depends(require_session)):
    return {"docs": docs_editor.list_docs(project_dir=settings.project_dir)}


@app.get("/api/docs/{doc_id}")
def api_docs_get(doc_id: str, _: None = Depends(require_session)):
    try:
        return docs_editor.read_doc(project_dir=settings.project_dir, doc_id=doc_id)
    except docs_editor.DocsError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc


@app.post("/api/docs/{doc_id}")
def api_docs_save(doc_id: str, body: DocSaveBody, _: None = Depends(require_session)):
    try:
        return docs_editor.write_doc(
            project_dir=settings.project_dir,
            doc_id=doc_id,
            content=body.content,
            expected_mtime=body.expected_mtime,
        )
    except docs_editor.DocsConflictError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    except docs_editor.DocsError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc


@app.get("/api/signal-chain/sheets")
def api_signal_chain_sheets(_: None = Depends(require_session)):
    try:
        return {"sheets": signal_chain_mod.list_sheets(project_dir=settings.project_dir)}
    except signal_chain_mod.SignalChainError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc


@app.get("/api/signal-chain/{sheet_id}/svg")
def api_signal_chain_svg(sheet_id: str, rankdir: str = "TB",
                         _: None = Depends(require_session)):
    if rankdir not in ("TB", "LR"):
        raise HTTPException(status_code=400, detail="rankdir must be TB or LR")
    try:
        svg = signal_chain_mod.render_svg(
            project_dir=settings.project_dir, sheet_id=sheet_id, rankdir=rankdir
        )
    except signal_chain_mod.SignalChainError as exc:
        # 422, not 500: a YAML typo or a bad link reference is the operator's
        # own edit, and the message says exactly which line/reference is wrong.
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    return Response(content=svg, media_type="image/svg+xml",
                    headers={"Cache-Control": "no-store"})


@app.websocket("/ws/agent")
async def ws_agent(websocket: WebSocket):
    if not websocket.session.get("authenticated"):
        await websocket.close(code=4401)
        return
    await websocket.accept()
    await agent_bridge.connect(websocket)
    try:
        while True:
            msg = await websocket.receive_json()
            kind = msg.get("type")
            if kind == "user_message":
                await agent_bridge.handle_user_message(websocket, msg.get("text", ""))
            elif kind == "confirm_result":
                await agent_bridge.operator_confirmed(
                    unit=msg.get("unit", ""),
                    action=msg.get("action", ""),
                    ok=bool(msg.get("ok")),
                    detail=msg.get("detail", ""),
                )
            elif kind == "reset":
                await agent_bridge.reset()
            # Anything else is ignored — the frontend and this handler are the
            # only speakers on this socket.
    except WebSocketDisconnect:
        pass
    finally:
        agent_bridge.disconnect(websocket)


# Mounted last and at "/" so it never shadows the /api or /ws routes above —
# FastAPI/Starlette match routes in registration order, and every explicit
# route was already registered by the time this catch-all mount is added.
# html=True serves static/index.html for "/" and lets a bare "/service.html"
# path resolve without the extension too.
_static_dir = Path(__file__).parent.parent / "static"
app.mount("/", StaticFiles(directory=_static_dir, html=True), name="static")

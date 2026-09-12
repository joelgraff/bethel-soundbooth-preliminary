"""The AI agent bridge — the chat panel's model, wired to the fixed toolset
in agent_tools.py.

Design (see dashboard/docs/agent-tools.md):
- **One session, not one per device.** A single AgentBridge instance holds
  the whole conversation; every connected chat panel sees the same stream and
  the same history. A second viewer joining mid-conversation is a feature
  (booth PC + someone on the LAN watching the same troubleshooting), not a
  bug to isolate.
- **The agent mirrors the dashboard's buttons and nothing more.** Every tool
  call routes through agent_tools.call_tool → units.check_action_allowed, the
  same gate the REST endpoints use. There is no shell, no file write, no unit
  off the manifest.
- **Confirm-gated actions (livestream start/stop) are staged, never
  completed, by the model.** call_tool passes confirm_token=None, so a
  confirm-gated action comes back as `requires_confirmation`; the bridge
  surfaces a Yes/No prompt to the operator and the actual execution is a
  fresh click in the operator's own session (frontend → existing REST
  endpoint). operator_confirmed() then feeds the outcome back so the agent
  can acknowledge.
"""
from __future__ import annotations

import asyncio
import json
import logging

from starlette.concurrency import run_in_threadpool

from . import agent_tools
from .config import Settings

logger = logging.getLogger("soundbooth.agent")

# Kept short on purpose: booth chats are a few turns, and a shorter history is
# cheaper and less likely to drift. Trimmed from the oldest end, never below a
# valid (user-first, no orphan tool_result) prefix.
_MAX_HISTORY_MESSAGES = 40
_MAX_TOKENS = 4096

SYSTEM_PROMPT = """\
You are the assistant built into the Soundbooth Control Dashboard for a church \
audio/video booth. The people talking to you are usually non-technical Sunday \
volunteers who just want the service to run.

What you can do (these are your only tools — you have no shell and no file \
access):
- get_health_status / list_services / get_service_log — check what's wrong and \
  read logs for a service.
- get_output_status — whether a video output (DP-2, DP-3, DP-4, or the \
  LIVESTREAM encode leg) currently has a live preview frame.
- read_doc — read one of a few project reference docs for how the booth is \
  meant to be set up.
- restart_service — restart a stuck service. Safe and self-healing; just do it \
  when a service looks wedged.
- start_service / stop_service — for the livestream relay this only *stages* \
  the action and shows the operator a Yes/No prompt. You cannot start or stop \
  the live broadcast yourself. Never say you have — say you've staged it and \
  ask them to click Confirm.

Style:
- Be brief and concrete. Lead with the answer or the action, not a preamble.
- Use plain names ("the program display", "the FOH bridge"), not unit \
  filenames, unless the operator asks for detail.
- If a restart doesn't fix it, say so and suggest what to check physically \
  (cables, power, the board) instead of restarting again in a loop.
- You can't fix hardware, network, or anything off this dashboard. Say when \
  something is outside what you can touch.
"""


def _tool_call_summary(name: str, tool_input: dict) -> str:
    tool_input = tool_input or {}
    if name in ("get_service_log",):
        return f"reading logs for {tool_input.get('unit', '?')}"
    if name in ("restart_service", "start_service", "stop_service"):
        verb = name.split("_")[0]
        return f"{verb}ing {tool_input.get('unit', '?')}"
    if name == "get_output_status":
        return f"checking {tool_input.get('display', '?')} preview"
    if name == "read_doc":
        return f"reading {tool_input.get('name', '?')}"
    return {"get_health_status": "running the health check",
            "list_services": "listing services"}.get(name, name)


class AgentBridge:
    def __init__(self, settings: Settings) -> None:
        self._settings = settings
        self._model = settings.agent_model
        self._tool_specs = agent_tools.build_tool_specs(settings.manifest_path)
        self._messages: list[dict] = []
        self._turn_lock = asyncio.Lock()
        self._clients: set = set()

        self._client = None
        if settings.anthropic_api_key:
            # Imported here so a missing/broken SDK can't stop the rest of the
            # dashboard from starting.
            from anthropic import AsyncAnthropic

            self._client = AsyncAnthropic(api_key=settings.anthropic_api_key)

    @property
    def configured(self) -> bool:
        return self._client is not None

    # ---- connection bookkeeping -------------------------------------------

    async def connect(self, websocket) -> None:
        self._clients.add(websocket)
        await self._send(websocket, {
            "type": "ready",
            "configured": self.configured,
            "model": self._model,
            "busy": self._turn_lock.locked(),
        })
        if not self.configured:
            await self._send(websocket, {
                "type": "system",
                "text": "The agent has no API key yet. Add ANTHROPIC_API_KEY to "
                        "~/.config/soundbooth/dashboard.conf and restart the "
                        "dashboard service.",
            })

    def disconnect(self, websocket) -> None:
        self._clients.discard(websocket)

    async def _send(self, websocket, event: dict) -> None:
        try:
            await websocket.send_json(event)
        except Exception:
            self._clients.discard(websocket)

    async def _broadcast(self, event: dict) -> None:
        for ws in list(self._clients):
            await self._send(ws, event)

    # ---- history --------------------------------------------------------

    def _trim_history(self) -> None:
        msgs = self._messages
        while len(msgs) > _MAX_HISTORY_MESSAGES:
            msgs.pop(0)
        # Don't leave the history starting on an assistant turn or on a
        # tool_result-only user turn (the matching tool_use would be gone).
        while msgs:
            first = msgs[0]
            if first["role"] != "user":
                msgs.pop(0)
                continue
            content = first["content"]
            if isinstance(content, list) and any(
                isinstance(b, dict) and b.get("type") == "tool_result" for b in content
            ):
                msgs.pop(0)
                continue
            break

    async def reset(self) -> None:
        async with self._turn_lock:
            self._messages = []
        await self._broadcast({"type": "system", "text": "New conversation."})
        await self._broadcast({"type": "turn_done"})

    # ---- inbound from a chat panel -------------------------------------

    async def handle_user_message(self, websocket, text: str) -> None:
        text = (text or "").strip()
        if not text:
            return
        if not self.configured:
            await self._send(websocket, {
                "type": "error",
                "text": "The agent isn't configured — no ANTHROPIC_API_KEY.",
            })
            return
        if self._turn_lock.locked():
            await self._send(websocket, {
                "type": "busy",
                "text": "Still working on the previous message…",
            })
            return
        async with self._turn_lock:
            self._messages.append({"role": "user", "content": text})
            await self._broadcast({"type": "user_echo", "text": text})
            await self._run_turn()

    async def operator_confirmed(
        self, unit: str, action: str, ok: bool, detail: str = ""
    ) -> None:
        """Called after the operator clicked Confirm/Cancel on a staged
        action and the frontend ran (or skipped) the REST call. Feeds the
        outcome back into the conversation so the agent can react."""
        if action == "confirm-cancelled":
            note = f"[Dashboard] The operator cancelled the staged {unit} action."
        elif ok:
            note = (f"[Dashboard] The operator confirmed and the system executed: "
                    f"{action} {unit}. Result: {detail or 'done'}.")
        else:
            note = (f"[Dashboard] The operator confirmed {action} {unit} but it "
                    f"failed: {detail or 'unknown error'}.")

        if self._turn_lock.locked():
            # A turn is already running (unusual — the operator clicked while
            # the agent was mid-thought). Just record it; the agent will see
            # it on the next turn.
            self._messages.append({"role": "user", "content": note})
            await self._broadcast({"type": "system", "text": note})
            return
        async with self._turn_lock:
            self._messages.append({"role": "user", "content": note})
            await self._broadcast({"type": "system", "text": note})
            await self._run_turn()

    # ---- the model loop ----------------------------------------------

    async def _run_turn(self) -> None:
        import anthropic

        await self._broadcast({"type": "turn_start"})
        try:
            while True:
                self._trim_history()
                async with self._client.messages.stream(
                    model=self._model,
                    max_tokens=_MAX_TOKENS,
                    system=[{
                        "type": "text",
                        "text": SYSTEM_PROMPT,
                        "cache_control": {"type": "ephemeral"},
                    }],
                    tools=self._tool_specs,
                    output_config={"effort": "low"},
                    messages=self._messages,
                ) as stream:
                    async for text in stream.text_stream:
                        await self._broadcast({"type": "token", "text": text})
                    final = await stream.get_final_message()

                self._messages.append({"role": "assistant", "content": final.content})

                if final.stop_reason != "tool_use":
                    break

                tool_results = []
                for block in final.content:
                    if block.type != "tool_use":
                        continue
                    tool_results.append(await self._execute_tool(block))
                self._messages.append({"role": "user", "content": tool_results})
        except anthropic.APIStatusError as exc:
            logger.warning("agent turn failed: %s", exc)
            await self._broadcast({
                "type": "error",
                "text": f"Model error ({exc.status_code}). Try again in a moment.",
            })
        except Exception as exc:  # noqa: BLE001 - surface anything else, don't wedge the socket
            logger.exception("agent turn crashed")
            await self._broadcast({"type": "error", "text": f"Agent error: {exc}"})
        finally:
            await self._broadcast({"type": "turn_done"})

    async def _execute_tool(self, block) -> dict:
        name, tool_input, tool_use_id = block.name, dict(block.input or {}), block.id
        await self._broadcast({
            "type": "tool_call",
            "name": name,
            "summary": _tool_call_summary(name, tool_input),
        })
        try:
            result = await run_in_threadpool(
                agent_tools.call_tool, name, tool_input, settings=self._settings
            )
        except Exception as exc:  # noqa: BLE001 - bad unit, failed systemctl, etc.
            await self._broadcast({
                "type": "tool_done", "name": name, "ok": False, "summary": str(exc),
            })
            return {
                "type": "tool_result",
                "tool_use_id": tool_use_id,
                "content": f"Error: {exc}",
                "is_error": True,
            }

        # A confirm-gated start/stop that got staged: pull the token out of the
        # model's view, show the operator a real prompt, and tell the model to
        # wait rather than retry.
        if isinstance(result, dict) and result.get("requires_confirmation"):
            token = result.pop("confirm_token", None)
            action = "stop" if name == "stop_service" else "start"
            unit = tool_input.get("unit", "")
            await self._broadcast({
                "type": "confirm_request",
                "unit": unit,
                "action": action,
                "message": result.get("message", "Confirm this action?"),
                "token": token,
            })
            await self._broadcast({
                "type": "tool_done", "name": name, "ok": True, "summary": "awaiting operator",
            })
            return {
                "type": "tool_result",
                "tool_use_id": tool_use_id,
                "content": json.dumps({
                    "staged": True,
                    "requires_confirmation": True,
                    "message": result.get("message"),
                    "note": "A Yes/No prompt is now shown to the operator in the "
                            "dashboard. They must click Confirm for this to take "
                            "effect. You cannot complete it yourself — do not call "
                            "this tool again; wait for the operator.",
                }),
            }

        await self._broadcast({"type": "tool_done", "name": name, "ok": True, "summary": "done"})
        return {
            "type": "tool_result",
            "tool_use_id": tool_use_id,
            "content": json.dumps(result, default=str),
        }

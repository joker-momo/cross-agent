"""FastAPI server: REST control + SSE event stream for the web UI."""

from __future__ import annotations

import asyncio
import json
import queue
import threading
import webbrowser

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from sse_starlette.sse import EventSourceResponse

from . import health as health_mod
from . import projects as projects_mod
from .config import DEFAULT_HOST, DEFAULT_PORT, Agent, Roles, RunConfig
from .runmanager import _SENTINEL, RunManager

app = FastAPI(title="Trinity")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

manager = RunManager()


# --- schemas ---
class ProjectIn(BaseModel):
    path: str


class RolesIn(BaseModel):
    planner: Agent
    implementer: Agent
    reviewer: Agent


class RunIn(BaseModel):
    project: str
    request: str
    roles: RolesIn
    max_iter: int = 5
    escalate_after: int = 2


# --- agents ---
@app.get("/agents")
def get_agents():
    return {"agents": health_mod.check_all()}


# --- projects ---
@app.get("/projects")
def get_projects():
    return {"projects": projects_mod.list_projects()}


@app.post("/projects")
def post_project(body: ProjectIn):
    try:
        return {"projects": projects_mod.add_project(body.path)}
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))


@app.delete("/projects")
def delete_project(body: ProjectIn):
    return {"projects": projects_mod.remove_project(body.path)}


# --- runs ---
@app.get("/runs")
def get_runs():
    return {"runs": manager.list_runs()}


@app.post("/runs")
def post_run(body: RunIn):
    roles = Roles(planner=body.roles.planner,
                  implementer=body.roles.implementer,
                  reviewer=body.roles.reviewer)
    cfg = RunConfig(max_iter=body.max_iter, escalate_after=body.escalate_after)
    run_id = manager.start(body.project, body.request, roles, cfg)
    return {"run_id": run_id}


@app.get("/run/{run_id}")
def get_run(run_id: str):
    rec = manager.get_run(run_id)
    if not rec:
        raise HTTPException(status_code=404, detail="run not found")
    return rec


@app.post("/run/{run_id}/stop")
def stop_run(run_id: str):
    if not manager.stop(run_id):
        raise HTTPException(status_code=404, detail="run not found or finished")
    return {"stopping": run_id}


@app.get("/run/{run_id}/events")
async def run_events(run_id: str):
    q = manager.subscribe(run_id)
    loop = asyncio.get_event_loop()

    async def gen():
        try:
            while True:
                item = await loop.run_in_executor(None, q.get)
                if item is _SENTINEL:
                    yield {"event": "end", "data": "{}"}
                    break
                yield {"event": item.get("type", "message"),
                       "data": json.dumps(item.get("data", {}))}
        finally:
            manager.unsubscribe(run_id, q)

    return EventSourceResponse(gen())


def _mount_frontend() -> None:
    """Serve the built React app at / if frontend/dist exists."""
    from pathlib import Path

    from fastapi.staticfiles import StaticFiles

    dist = Path(__file__).resolve().parents[2] / "frontend" / "dist"
    if dist.is_dir():
        app.mount("/", StaticFiles(directory=str(dist), html=True), name="ui")


def serve(host: str = DEFAULT_HOST, port: int = DEFAULT_PORT,
          open_browser: bool = True) -> None:
    import uvicorn
    _mount_frontend()
    if open_browser:
        threading.Timer(
            1.0, lambda: webbrowser.open(f"http://{host}:{port}")
        ).start()
    uvicorn.run(app, host=host, port=port, log_level="info")

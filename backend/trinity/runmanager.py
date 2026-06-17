"""In-process run lifecycle: spawn orchestrator in a thread, bridge events.

MVP scope: single run at a time per process is allowed but we key by run_id so
the UI can address a specific run. Events are buffered per run and also fanned
out to any live SSE subscribers via thread-safe queues.
"""

from __future__ import annotations

import queue
import threading
from dataclasses import asdict, dataclass, field
from pathlib import Path

from .config import Agent, Roles, RunConfig
from .orchestrator import Event, Orchestrator

_SENTINEL = object()


@dataclass
class RunRecord:
    run_id: str
    project: str
    request: str
    roles: dict
    state: str = "pending"
    stop_reason: str | None = None
    branch: str | None = None
    iteration: int = 0
    history: list[dict] = field(default_factory=list)


class RunManager:
    def __init__(self):
        self._runs: dict[str, RunRecord] = {}
        self._cancels: dict[str, threading.Event] = {}
        self._subscribers: dict[str, list[queue.Queue]] = {}
        self._lock = threading.Lock()

    def list_runs(self) -> list[dict]:
        with self._lock:
            return [asdict(r) for r in self._runs.values()]

    def get_run(self, run_id: str) -> dict | None:
        with self._lock:
            r = self._runs.get(run_id)
            return asdict(r) if r else None

    def stop(self, run_id: str) -> bool:
        ev = self._cancels.get(run_id)
        if ev:
            ev.set()
            return True
        return False

    def subscribe(self, run_id: str) -> queue.Queue:
        q: queue.Queue = queue.Queue()
        with self._lock:
            self._subscribers.setdefault(run_id, []).append(q)
            rec = self._runs.get(run_id)
        # Replay history so a late subscriber catches up.
        if rec:
            for item in rec.history:
                q.put(item)
            if rec.stop_reason is not None:
                q.put(_SENTINEL)
        return q

    def unsubscribe(self, run_id: str, q: queue.Queue) -> None:
        with self._lock:
            subs = self._subscribers.get(run_id, [])
            if q in subs:
                subs.remove(q)

    def _dispatch(self, run_id: str, payload: dict) -> None:
        with self._lock:
            rec = self._runs.get(run_id)
            if rec:
                rec.history.append(payload)
                if payload.get("type") == "state":
                    d = payload["data"]
                    rec.state = d.get("state", rec.state)
                    rec.iteration = d.get("iteration", rec.iteration)
                    rec.branch = d.get("branch", rec.branch)
                    if d.get("stop_reason"):
                        rec.stop_reason = d["stop_reason"]
            subs = list(self._subscribers.get(run_id, []))
        for q in subs:
            q.put(payload)

    def start(self, project: str, request: str, roles: Roles,
              config: RunConfig | None = None) -> str:
        from .artifacts import new_run_id
        run_id = new_run_id()
        rec = RunRecord(run_id=run_id, project=project, request=request,
                        roles=roles.as_dict())
        cancel_ev = threading.Event()
        with self._lock:
            self._runs[run_id] = rec
            self._cancels[run_id] = cancel_ev

        def emit(e: Event) -> None:
            self._dispatch(run_id, {"type": e.type, "data": e.data})

        def worker() -> None:
            orch = Orchestrator(emit=emit, config=config,
                                cancel=cancel_ev.is_set)
            try:
                # Orchestrator picks its own run_id; we mirror state by run_id
                # used in the manager. For MVP we let it run and rely on events.
                orch.run(Path(project), request, roles, run_id=run_id)
            except Exception as exc:  # pragma: no cover - safety net
                self._dispatch(run_id, {
                    "type": "stop",
                    "data": {"stop_reason": "agent_error", "message": str(exc)},
                })
                with self._lock:
                    rec.stop_reason = "agent_error"
            finally:
                with self._lock:
                    subs = list(self._subscribers.get(run_id, []))
                for q in subs:
                    q.put(_SENTINEL)

        threading.Thread(target=worker, name=f"run-{run_id}", daemon=True).start()
        return run_id

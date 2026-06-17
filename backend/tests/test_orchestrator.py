import json
from pathlib import Path

import pytest

from trinity.agents import AgentError, AgentResult
from trinity.config import Agent, Role, Roles, RunConfig, State, StopReason
from trinity.orchestrator import Event, Orchestrator


# --- fakes ---------------------------------------------------------------

class FakeGit:
    def __init__(self):
        self.changed = False
        self.checkpoints = []
        self.branch = None

    def preflight(self, cwd): pass
    def is_dirty(self, cwd): return False
    def stash(self, cwd): pass
    def slugify(self, text): return "slug"

    def create_branch(self, cwd, slug):
        self.branch = f"trinity/{slug}"
        return self.branch

    def has_changes(self, cwd):
        return self.changed

    def checkpoint(self, cwd, message):
        self.checkpoints.append(message)
        self.changed = False
        return "deadbeef"

    def diff(self, cwd):
        return "diff --git a/x b/x"


def verdict_json(approved, blocking=None):
    return json.dumps({
        "approved": approved,
        "blocking_issues": blocking or [],
        "minor_notes": [],
        "reason": "approved" if approved else "needs work",
    })


def make_invoke(script, git: FakeGit):
    """script: callable(agent, role, call_index) -> stdout str | Exception."""
    calls = {"n": 0}

    def invoke(agent, role, prompt, *, cwd, timeout_s):
        i = calls["n"]
        calls["n"] += 1
        if role is Role.IMPLEMENTER:
            git.changed = True
        out = script(agent, role, i)
        if isinstance(out, Exception):
            raise out
        return AgentResult(returncode=0, stdout=out, stderr="",
                           command=[agent.value, role.value])

    invoke.calls = calls
    return invoke


ROLES = Roles(planner=Agent.CLAUDE, implementer=Agent.AGY, reviewer=Agent.CODEX)


def collect_events():
    events = []
    return events, (lambda e: events.append(e))


# --- tests ---------------------------------------------------------------

def test_approve_first_iteration(tmp_path):
    git = FakeGit()

    def script(agent, role, i):
        if role is Role.REVIEWER:
            return verdict_json(True)
        return "ok"

    events, emit = collect_events()
    orch = Orchestrator(invoke=make_invoke(script, git), git=git, emit=emit)
    res = orch.run(tmp_path, "build feature", ROLES)

    assert res.stop_reason is StopReason.APPROVED
    assert res.iterations == 1
    assert res.last_verdict.approved is True
    assert git.checkpoints == ["wip: iter 1"]
    # status.json persisted with DONE state
    status = json.loads((tmp_path / ".trinity" / "runs" / res.run_id
                         / "status.json").read_text())
    assert status["state"] == State.DONE.value
    assert status["stop_reason"] == "approved"


def test_max_iterations_without_escalation(tmp_path):
    git = FakeGit()
    cfg = RunConfig(max_iter=3, escalate_after=99)  # never escalate

    def script(agent, role, i):
        if role is Role.REVIEWER:
            return verdict_json(False, ["still broken"])
        return "ok"

    orch = Orchestrator(invoke=make_invoke(script, git), git=git, config=cfg)
    res = orch.run(tmp_path, "task", ROLES)
    assert res.stop_reason is StopReason.MAX_ITERATIONS
    assert res.iterations == 3
    assert len(git.checkpoints) == 3


def test_escalation_then_plan_rejected(tmp_path):
    git = FakeGit()
    cfg = RunConfig(max_iter=5, escalate_after=2)
    planner_calls = []

    def script(agent, role, i):
        if role is Role.PLANNER:
            planner_calls.append(i)
            return "plan"
        if role is Role.REVIEWER:
            return verdict_json(False, ["nope"])
        return "ok"

    orch = Orchestrator(invoke=make_invoke(script, git), git=git, config=cfg)
    res = orch.run(tmp_path, "task", ROLES)
    assert res.stop_reason is StopReason.PLAN_REJECTED
    # planner: 1 initial + 2 re-plans (after iter2 and iter4)
    assert len(planner_calls) >= 3


def test_no_changes_stop(tmp_path):
    git = FakeGit()

    def invoke(agent, role, prompt, *, cwd, timeout_s):
        # implementer never marks changes
        return AgentResult(0, "ok", "", [agent.value, role.value])

    orch = Orchestrator(invoke=invoke, git=git)
    res = orch.run(tmp_path, "task", ROLES)
    assert res.stop_reason is StopReason.NO_CHANGES
    assert res.iterations == 1


def test_agent_error_stop(tmp_path):
    git = FakeGit()

    def script(agent, role, i):
        if role is Role.IMPLEMENTER:
            return AgentError("agy crashed")
        return "ok"

    orch = Orchestrator(invoke=make_invoke(script, git), git=git)
    res = orch.run(tmp_path, "task", ROLES)
    assert res.stop_reason is StopReason.AGENT_ERROR
    assert "crashed" in res.message


def test_verdict_unparseable_stop(tmp_path):
    git = FakeGit()

    def script(agent, role, i):
        if role is Role.REVIEWER:
            return "looks good to me, ship it"
        return "ok"

    orch = Orchestrator(invoke=make_invoke(script, git), git=git)
    res = orch.run(tmp_path, "task", ROLES)
    assert res.stop_reason is StopReason.VERDICT_UNPARSEABLE


def test_recovers_after_one_failure(tmp_path):
    git = FakeGit()
    state = {"review": 0}

    def script(agent, role, i):
        if role is Role.REVIEWER:
            state["review"] += 1
            return verdict_json(state["review"] >= 2,
                                ["fix"] if state["review"] < 2 else [])
        return "ok"

    orch = Orchestrator(invoke=make_invoke(script, git), git=git)
    res = orch.run(tmp_path, "task", ROLES)
    assert res.stop_reason is StopReason.APPROVED
    assert res.iterations == 2


def test_emits_stop_event(tmp_path):
    git = FakeGit()

    def script(agent, role, i):
        return verdict_json(True) if role is Role.REVIEWER else "ok"

    events, emit = collect_events()
    orch = Orchestrator(invoke=make_invoke(script, git), git=git, emit=emit)
    orch.run(tmp_path, "task", ROLES)
    types = [e.type for e in events]
    assert "stop" in types
    assert "verdict" in types
    assert any(e.type == "state" for e in events)

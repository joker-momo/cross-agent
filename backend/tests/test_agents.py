from pathlib import Path

import pytest

from trinity import agents
from trinity.agents import AgentError, AgentResult, build_command, run_agent
from trinity.config import Agent, Role


def test_claude_implementer_has_edit_flag():
    cmd = build_command(Agent.CLAUDE, Role.IMPLEMENTER, "do x")
    assert cmd[:3] == ["claude", "-p", "do x"]
    assert "--permission-mode" in cmd and "acceptEdits" in cmd
    assert "--output-format" not in cmd


def test_claude_reviewer_has_json_flag_no_edit():
    cmd = build_command(Agent.CLAUDE, Role.REVIEWER, "review")
    assert "--output-format" in cmd and "json" in cmd
    assert "--permission-mode" not in cmd


def test_codex_reviewer_uses_output_schema():
    cmd = build_command(Agent.CODEX, Role.REVIEWER, "review",
                        schema_path=Path("/tmp/review.schema.json"))
    assert cmd[:2] == ["codex", "exec"]
    assert "--output-schema" in cmd
    assert "/tmp/review.schema.json" in cmd


def test_codex_implementer_sandbox():
    cmd = build_command(Agent.CODEX, Role.IMPLEMENTER, "go")
    assert "--sandbox" in cmd and "workspace-write" in cmd


def test_agy_always_yes():
    cmd = build_command(Agent.AGY, Role.IMPLEMENTER, "go")
    assert cmd[0] == "agy" and "--yes" in cmd


def test_agy_reviewer_json():
    cmd = build_command(Agent.AGY, Role.REVIEWER, "review")
    assert "--output-format" in cmd and "json" in cmd


def test_run_agent_success(monkeypatch, tmp_path):
    class FakeProc:
        returncode = 0
        stdout = "hello"
        stderr = ""

    def fake_run(cmd, **kwargs):
        assert kwargs["cwd"] == str(tmp_path)
        assert kwargs["stdin"] is not None  # DEVNULL
        return FakeProc()

    monkeypatch.setattr(agents.subprocess, "run", fake_run)
    res = run_agent(Agent.CLAUDE, Role.PLANNER, "plan", cwd=tmp_path, timeout_s=10)
    assert isinstance(res, AgentResult)
    assert res.ok and res.stdout == "hello"


def test_run_agent_nonzero_raises(monkeypatch, tmp_path):
    class FakeProc:
        returncode = 2
        stdout = ""
        stderr = "boom"

    monkeypatch.setattr(agents.subprocess, "run", lambda cmd, **k: FakeProc())
    with pytest.raises(AgentError) as ei:
        run_agent(Agent.CODEX, Role.IMPLEMENTER, "go", cwd=tmp_path, timeout_s=5)
    assert ei.value.result.stderr == "boom"


def test_run_agent_timeout_raises(monkeypatch, tmp_path):
    def fake_run(cmd, **kwargs):
        raise agents.subprocess.TimeoutExpired(cmd, 5)

    monkeypatch.setattr(agents.subprocess, "run", fake_run)
    with pytest.raises(AgentError):
        run_agent(Agent.AGY, Role.REVIEWER, "x", cwd=tmp_path, timeout_s=5)

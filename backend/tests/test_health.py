import json

from trinity import health
from trinity.config import Agent


def test_codex_account_reads_auth_and_rate_limits(tmp_path, monkeypatch):
    codex_home = tmp_path / ".codex"
    sessions = codex_home / "sessions"
    sessions.mkdir(parents=True)
    (codex_home / "auth.json").write_text(json.dumps({
        "tokens": {"account_id": "acct_123"},
        "user": {"email": "dev@example.com"},
    }))
    (sessions / "rollout.jsonl").write_text(
        json.dumps({
            "rate_limits": {
                "primary_window": {
                    "used_percent": 32,
                    "limit_window_seconds": 18_000,
                },
                "secondary_window": {
                    "used_percent": 70,
                    "limit_window_seconds": 604_800,
                },
            }
        }) + "\n"
    )
    monkeypatch.setattr(health, "_CODEX_HOME", codex_home)

    status = health.AgentStatus("codex", installed=True, status="ready")
    health._attach_account(Agent.CODEX, status)

    assert status.account == "dev@example.com"
    assert status.quota_remaining == "5h 68% left; weekly 30% left"
    assert status.can_switch is True


def test_codex_account_falls_back_to_account_id(tmp_path, monkeypatch):
    codex_home = tmp_path / ".codex"
    codex_home.mkdir()
    (codex_home / "auth.json").write_text(json.dumps({
        "tokens": {"account_id": "acct_123"},
    }))
    monkeypatch.setattr(health, "_CODEX_HOME", codex_home)

    status = health.AgentStatus("codex", installed=True, status="ready")
    health._attach_account(Agent.CODEX, status)

    assert status.account == "acct_123"


def test_codex_switch_flow_supported(monkeypatch):
    launched = []

    def fake_run(cmd, **kwargs):
        launched.append(cmd)

        class Proc:
            returncode = 0

        return Proc()

    monkeypatch.setattr(health.subprocess, "run", fake_run)

    assert health.switch_account(Agent.CODEX, "login") == "codex login"
    assert launched[0][0] == "osascript"

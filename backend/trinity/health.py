"""Lightweight agent CLI connectivity checks for the UI status panel."""

from __future__ import annotations

import shutil
import subprocess
from dataclasses import dataclass, field

from .config import Agent

# Command that proves the binary runs without side effects.
_VERSION_ARGS: dict[Agent, list[str]] = {
    Agent.CLAUDE: ["--version"],
    Agent.CODEX: ["--version"],
    Agent.AGY: ["--version"],
}


@dataclass
class AgentStatus:
    agent: str
    installed: bool
    version: str = ""
    status: str = "missing"  # missing | ready | error
    detail: str = ""

    def as_dict(self) -> dict:
        return {
            "agent": self.agent,
            "installed": self.installed,
            "version": self.version,
            "status": self.status,
            "detail": self.detail,
        }


def check_agent(agent: Agent, *, timeout_s: int = 8) -> AgentStatus:
    """Resolve the CLI on PATH and confirm it runs. No auth probe (would be
    slow + side-effecting); reports whether the binary is present and works."""
    path = shutil.which(agent.value)
    if not path:
        return AgentStatus(agent.value, installed=False, status="missing",
                           detail="not found on PATH")
    try:
        proc = subprocess.run(
            [agent.value, *_VERSION_ARGS[agent]],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=timeout_s,
        )
    except subprocess.TimeoutExpired:
        return AgentStatus(agent.value, installed=True, status="error",
                           detail=f"version check timed out ({timeout_s}s)")
    except OSError as e:
        return AgentStatus(agent.value, installed=True, status="error",
                           detail=str(e))

    version = (proc.stdout or proc.stderr or "").strip().splitlines()
    ver = version[0] if version else ""
    if proc.returncode == 0:
        return AgentStatus(agent.value, installed=True, version=ver,
                           status="ready")
    return AgentStatus(agent.value, installed=True, version=ver,
                       status="error",
                       detail=(proc.stderr or "").strip()[:200])


def check_all(timeout_s: int = 8) -> list[dict]:
    return [check_agent(a, timeout_s=timeout_s).as_dict() for a in Agent]

"""Agent adapter: one interface, three CLI backends (claude / codex / agy).

Each backend still reads its own project rules (AGENTS.md / CLAUDE.md / .agent)
because the agent CLI is invoked INSIDE the target project directory.
"""

from __future__ import annotations

import subprocess
from dataclasses import dataclass
from pathlib import Path

from .config import REVIEW_SCHEMA_PATH, Agent, Role


@dataclass
class AgentResult:
    returncode: int
    stdout: str
    stderr: str
    command: list[str]

    @property
    def ok(self) -> bool:
        return self.returncode == 0


class AgentError(RuntimeError):
    """Agent crashed, timed out, or exited non-zero."""

    def __init__(self, message: str, result: AgentResult | None = None):
        super().__init__(message)
        self.result = result


# Roles that write files in the target project need edit permission.
_EDIT_ROLES = {Role.PLANNER, Role.IMPLEMENTER}
# The reviewer must emit a machine-checkable JSON verdict.
_JSON_ROLES = {Role.REVIEWER}


def build_command(
    agent: Agent,
    role: Role,
    prompt: str,
    *,
    schema_path: Path = REVIEW_SCHEMA_PATH,
) -> list[str]:
    """Construct the CLI argv for the given agent+role. No execution."""
    needs_edit = role in _EDIT_ROLES
    needs_json = role in _JSON_ROLES

    if agent is Agent.CLAUDE:
        cmd = ["claude", "-p", prompt]
        if needs_edit:
            cmd += ["--permission-mode", "acceptEdits"]
        if needs_json:
            cmd += ["--output-format", "json"]
        return cmd

    if agent is Agent.CODEX:
        cmd = ["codex", "exec", prompt]
        if needs_edit:
            cmd += ["--sandbox", "workspace-write"]
        if needs_json:
            # Codex enforces the schema -> most reliable reviewer backend.
            cmd += ["--output-schema", str(schema_path)]
        return cmd

    if agent is Agent.AGY:
        cmd = ["agy", "-p", prompt, "--yes"]
        if needs_json:
            cmd += ["--output-format", "json"]
        return cmd

    raise ValueError(f"unknown agent: {agent!r}")


def run_agent(
    agent: Agent,
    role: Role,
    prompt: str,
    *,
    cwd: Path,
    timeout_s: int,
    schema_path: Path = REVIEW_SCHEMA_PATH,
) -> AgentResult:
    """Run the agent CLI inside the target project. Raises AgentError on failure.

    Uses stdin=/dev/null (empty) to dodge the agy non-TTY stdout-drop bug.
    """
    cmd = build_command(agent, role, prompt, schema_path=schema_path)
    try:
        proc = subprocess.run(
            cmd,
            cwd=str(cwd),
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=timeout_s,
        )
    except subprocess.TimeoutExpired as e:
        raise AgentError(
            f"{agent.value} as {role.value} timed out after {timeout_s}s"
        ) from e
    except FileNotFoundError as e:
        raise AgentError(f"{agent.value} CLI not found on PATH") from e

    result = AgentResult(
        returncode=proc.returncode,
        stdout=proc.stdout or "",
        stderr=proc.stderr or "",
        command=cmd,
    )
    if not result.ok:
        raise AgentError(
            f"{agent.value} as {role.value} exited {proc.returncode}", result
        )
    return result

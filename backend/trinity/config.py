"""Defaults, paths, and role/agent enums."""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum
from pathlib import Path

# --- Tool-global state location (outside any target project) ---
TRINITY_HOME = Path.home() / ".trinity"
PROJECTS_FILE = TRINITY_HOME / "projects.json"
RUNS_DIR = TRINITY_HOME / "runs"

# --- Schema bundled with the tool ---
SCHEMA_DIR = Path(__file__).parent / "schema"
REVIEW_SCHEMA_PATH = SCHEMA_DIR / "review.schema.json"

# --- Per-target-project artifact subdir ---
TRINITY_SUBDIR = ".trinity"


class Agent(str, Enum):
    CLAUDE = "claude"
    CODEX = "codex"
    AGY = "agy"


class Role(str, Enum):
    PLANNER = "planner"
    IMPLEMENTER = "implementer"
    REVIEWER = "reviewer"


class State(str, Enum):
    PENDING = "pending"
    PLANNING = "planning"
    IMPLEMENTING = "implementing"
    REVIEWING = "reviewing"
    DONE = "done"
    STOPPED = "stopped"


class StopReason(str, Enum):
    APPROVED = "approved"
    MAX_ITERATIONS = "max_iterations"
    PLAN_REJECTED = "plan_rejected"
    AGENT_ERROR = "agent_error"
    VERDICT_UNPARSEABLE = "verdict_unparseable"
    NO_CHANGES = "no_changes"
    CANCELLED = "cancelled"


@dataclass
class RunConfig:
    """Per-run tunables."""

    max_iter: int = 5
    escalate_after: int = 2
    call_timeout_s: int = 20 * 60  # 20 minutes


@dataclass
class Roles:
    """Which agent plays each role for a given task."""

    planner: Agent
    implementer: Agent
    reviewer: Agent

    def as_dict(self) -> dict[str, str]:
        return {
            "planner": self.planner.value,
            "implementer": self.implementer.value,
            "reviewer": self.reviewer.value,
        }


# Default server settings
DEFAULT_PORT = 7777
DEFAULT_HOST = "127.0.0.1"

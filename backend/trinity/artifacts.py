"""Per-run artifact storage inside the target project (.trinity/runs/<id>/)."""

from __future__ import annotations

import json
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

from .config import TRINITY_SUBDIR


def new_run_id() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")


@dataclass
class RunArtifacts:
    """Owns the on-disk layout for a single run within a target project."""

    project_dir: Path
    run_id: str

    @property
    def root(self) -> Path:
        return self.project_dir / TRINITY_SUBDIR / "runs" / self.run_id

    def ensure(self) -> None:
        self.root.mkdir(parents=True, exist_ok=True)

    # --- typed file accessors ---
    @property
    def task_md(self) -> Path:
        return self.root / "task.md"

    @property
    def plan_md(self) -> Path:
        return self.root / "plan.md"

    @property
    def status_json(self) -> Path:
        return self.root / "status.json"

    @property
    def transcript_log(self) -> Path:
        return self.root / "transcript.log"

    def review_json(self, iteration: int) -> Path:
        return self.root / f"review-{iteration}.json"

    # --- writers ---
    def write_status(self, status: dict) -> None:
        self.status_json.write_text(json.dumps(status, indent=2))

    def append_transcript(self, text: str) -> None:
        with self.transcript_log.open("a") as f:
            f.write(text.rstrip("\n") + "\n")

    def write_review(self, iteration: int, verdict: dict) -> None:
        self.review_json(iteration).write_text(json.dumps(verdict, indent=2))

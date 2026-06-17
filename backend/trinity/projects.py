"""Saved target-project registry (~/.trinity/projects.json)."""

from __future__ import annotations

import json
from pathlib import Path

from .config import PROJECTS_FILE, TRINITY_HOME


def _load() -> list[str]:
    if not PROJECTS_FILE.exists():
        return []
    try:
        return json.loads(PROJECTS_FILE.read_text())
    except (json.JSONDecodeError, OSError):
        return []


def _save(paths: list[str]) -> None:
    TRINITY_HOME.mkdir(parents=True, exist_ok=True)
    PROJECTS_FILE.write_text(json.dumps(paths, indent=2))


def list_projects() -> list[str]:
    return _load()


def add_project(path: str) -> list[str]:
    resolved = str(Path(path).expanduser().resolve())
    if not Path(resolved).is_dir():
        raise ValueError(f"not a directory: {resolved}")
    paths = _load()
    if resolved not in paths:
        paths.append(resolved)
        _save(paths)
    return paths


def remove_project(path: str) -> list[str]:
    resolved = str(Path(path).expanduser().resolve())
    paths = [p for p in _load() if p != resolved]
    _save(paths)
    return paths

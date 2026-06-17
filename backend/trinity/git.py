"""Git guardrails for the target project: branch, checkpoint, safety checks."""

from __future__ import annotations

import re
import subprocess
from pathlib import Path

_PROTECTED = {"main", "master"}


class GitGuardError(RuntimeError):
    """A git safety guardrail refused to proceed."""


def _git(cwd: Path, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["git", *args],
        cwd=str(cwd),
        capture_output=True,
        text=True,
    )


def slugify(text: str, *, max_len: int = 40) -> str:
    """task request -> branch-safe slug."""
    s = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")
    return s[:max_len].strip("-") or "task"


def is_git_repo(cwd: Path) -> bool:
    r = _git(cwd, "rev-parse", "--is-inside-work-tree")
    return r.returncode == 0 and r.stdout.strip() == "true"


def current_branch(cwd: Path) -> str:
    r = _git(cwd, "rev-parse", "--abbrev-ref", "HEAD")
    return r.stdout.strip()


def is_dirty(cwd: Path) -> bool:
    r = _git(cwd, "status", "--porcelain")
    return bool(r.stdout.strip())


def preflight(cwd: Path) -> None:
    """Refuse to run on a protected branch. Caller handles dirty separately."""
    if not is_git_repo(cwd):
        raise GitGuardError(f"{cwd} is not a git repository")
    branch = current_branch(cwd)
    if branch in _PROTECTED:
        raise GitGuardError(
            f"refusing to run on protected branch '{branch}'; "
            "Trinity creates its own trinity/<slug> branch"
        )


def stash(cwd: Path, message: str = "trinity: pre-run stash") -> None:
    r = _git(cwd, "stash", "push", "-u", "-m", message)
    if r.returncode != 0:
        raise GitGuardError(f"stash failed: {r.stderr.strip()}")


def create_branch(cwd: Path, slug: str) -> str:
    """Create + switch to trinity/<slug>. Idempotent-ish: appends -N on clash."""
    base = f"trinity/{slug}"
    name = base
    n = 2
    while True:
        exists = _git(cwd, "rev-parse", "--verify", name).returncode == 0
        if not exists:
            break
        name = f"{base}-{n}"
        n += 1
    r = _git(cwd, "checkout", "-b", name)
    if r.returncode != 0:
        raise GitGuardError(f"branch create failed: {r.stderr.strip()}")
    return name


def has_changes(cwd: Path) -> bool:
    """True if there is anything to commit (tracked or untracked)."""
    return is_dirty(cwd)


def checkpoint(cwd: Path, message: str) -> str | None:
    """Stage all + commit. Returns commit sha, or None if nothing to commit."""
    if not has_changes(cwd):
        return None
    _git(cwd, "add", "-A")
    r = _git(cwd, "commit", "-m", message, "--no-verify")
    if r.returncode != 0:
        raise GitGuardError(f"checkpoint commit failed: {r.stderr.strip()}")
    sha = _git(cwd, "rev-parse", "HEAD").stdout.strip()
    return sha


def diff(cwd: Path, *, staged: bool = False) -> str:
    args = ["diff"]
    if staged:
        args.append("--cached")
    return _git(cwd, *args).stdout

import subprocess
from pathlib import Path

import pytest

from trinity import git
from trinity.git import GitGuardError


def _run(cwd, *args):
    subprocess.run(["git", *args], cwd=str(cwd), check=True,
                   capture_output=True, text=True)


@pytest.fixture
def repo(tmp_path):
    _run(tmp_path, "init", "-b", "main")
    _run(tmp_path, "config", "user.email", "t@t.t")
    _run(tmp_path, "config", "user.name", "t")
    (tmp_path / "README.md").write_text("hi")
    _run(tmp_path, "add", "-A")
    _run(tmp_path, "commit", "-m", "init")
    return tmp_path


def test_slugify():
    assert git.slugify("Add OAuth login!") == "add-oauth-login"
    assert git.slugify("") == "task"


def test_preflight_refuses_on_main(repo):
    with pytest.raises(GitGuardError, match="protected branch"):
        git.preflight(repo)


def test_preflight_refuses_non_repo(tmp_path):
    with pytest.raises(GitGuardError, match="not a git repository"):
        git.preflight(tmp_path)


def test_create_branch_and_preflight_ok(repo):
    name = git.create_branch(repo, "my-task")
    assert name == "trinity/my-task"
    assert git.current_branch(repo) == "trinity/my-task"
    git.preflight(repo)  # no longer on main -> ok


def test_create_branch_collision_suffix(repo):
    git.create_branch(repo, "dup")
    _run(repo, "checkout", "main")
    name2 = git.create_branch(repo, "dup")
    assert name2 == "trinity/dup-2"


def test_dirty_detection_and_checkpoint(repo):
    git.create_branch(repo, "x")
    assert git.is_dirty(repo) is False
    (repo / "new.txt").write_text("change")
    assert git.is_dirty(repo) is True
    sha = git.checkpoint(repo, "wip: iter 1")
    assert sha and len(sha) == 40
    assert git.is_dirty(repo) is False


def test_checkpoint_noop_when_clean(repo):
    git.create_branch(repo, "x")
    assert git.checkpoint(repo, "nothing") is None


def test_stash_clears_dirty(repo):
    (repo / "scratch.txt").write_text("uncommitted")
    assert git.is_dirty(repo) is True
    git.stash(repo)
    assert git.is_dirty(repo) is False

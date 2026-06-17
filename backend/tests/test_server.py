import json

import pytest
from fastapi.testclient import TestClient

from trinity import projects as projects_mod
from trinity import server
from trinity.runmanager import RunManager


@pytest.fixture
def client(tmp_path, monkeypatch):
    # Isolate the projects registry to a temp file.
    pfile = tmp_path / "projects.json"
    monkeypatch.setattr(projects_mod, "PROJECTS_FILE", pfile)
    monkeypatch.setattr(projects_mod, "TRINITY_HOME", tmp_path)
    # Fresh run manager per test.
    monkeypatch.setattr(server, "manager", RunManager())
    return TestClient(server.app)


def test_agents_status_shape(client):
    r = client.get("/agents")
    assert r.status_code == 200
    agents = r.json()["agents"]
    names = {a["agent"] for a in agents}
    assert names == {"claude", "codex", "agy"}
    for a in agents:
        assert set(a) >= {"agent", "installed", "status"}
        assert a["status"] in {"ready", "missing", "error"}


def test_projects_empty(client):
    r = client.get("/projects")
    assert r.status_code == 200
    assert r.json() == {"projects": []}


def test_add_project(client, tmp_path):
    target = tmp_path / "proj"
    target.mkdir()
    r = client.post("/projects", json={"path": str(target)})
    assert r.status_code == 200
    assert str(target.resolve()) in r.json()["projects"]


def test_add_nonexistent_project_400(client):
    r = client.post("/projects", json={"path": "/no/such/dir/xyz"})
    assert r.status_code == 400


def test_remove_project(client, tmp_path):
    target = tmp_path / "proj"
    target.mkdir()
    client.post("/projects", json={"path": str(target)})
    r = client.request("DELETE", "/projects", json={"path": str(target)})
    assert r.status_code == 200
    assert r.json()["projects"] == []


def test_get_unknown_run_404(client):
    assert client.get("/run/nope").status_code == 404


def test_stop_unknown_run_404(client):
    assert client.post("/run/nope/stop").status_code == 404


def test_post_run_uses_manager(client, monkeypatch):
    captured = {}

    def fake_start(project, request, roles, config=None):
        captured["project"] = project
        captured["request"] = request
        captured["roles"] = roles.as_dict()
        captured["max_iter"] = config.max_iter
        return "run-xyz"

    monkeypatch.setattr(server.manager, "start", fake_start)
    r = client.post("/runs", json={
        "project": "/tmp/p",
        "request": "do it",
        "roles": {"planner": "claude", "implementer": "agy",
                  "reviewer": "codex"},
        "max_iter": 3,
    })
    assert r.status_code == 200
    assert r.json() == {"run_id": "run-xyz"}
    assert captured["roles"] == {"planner": "claude", "implementer": "agy",
                                 "reviewer": "codex"}
    assert captured["max_iter"] == 3


def test_runs_list_after_seed(client):
    # Seed a record directly into the manager.
    from trinity.runmanager import RunRecord
    server.manager._runs["r1"] = RunRecord(
        run_id="r1", project="/p", request="x",
        roles={"planner": "claude", "implementer": "agy", "reviewer": "codex"})
    r = client.get("/runs")
    assert r.status_code == 200
    ids = [run["run_id"] for run in r.json()["runs"]]
    assert "r1" in ids

# Trinity — Multi-Agent Orchestrator

Project-agnostic tool that runs a **plan → implement → review** loop across three
coding-agent CLIs — **Claude** (`claude`), **Codex** (`codex`), and
**Antigravity** (`agy`). You assign any agent to any role per task; the loop runs
full-auto until the reviewer approves or it stops with an explicit reason.

Design spec: [`docs/specs/2026-06-17-trinity-orchestrator-design.md`](docs/specs/2026-06-17-trinity-orchestrator-design.md).

## Layout

```
backend/    Python core engine + FastAPI server + CLI (package: trinity)
frontend/   React + Vite + TS + Tailwind web control center
```

## Backend

```bash
cd backend
uv sync
uv run pytest                 # 41 tests, no live agent calls
uv run trinity serve          # launches UI at http://127.0.0.1:7777 (auto-opens)
```

CLI control path (backup for the UI):

```bash
uv run trinity --project /path/to/project "Add OAuth login" \
  -P claude -I antigravity -R codex --max-iter 5 --escalate-after 2 --dry-run
```

## Frontend

```bash
cd frontend
pnpm install
pnpm dev      # dev server on :5173, proxies API to :7777
pnpm build    # outputs frontend/dist, served by `trinity serve`
```

## Desktop app (Tauri)

Native window that auto-spawns the Python backend on launch and kills it on
exit. Needs Rust + `uv` on the machine (backend is run as `uv run trinity
serve`, not frozen).

```bash
cd frontend
pnpm install
pnpm desktop          # dev: launches the Trinity window (spawns backend on :7777)
pnpm desktop:build    # produces a .app / .dmg under src-tauri/target/release/bundle
```

The Rust shell (`src-tauri/`) resolves the repo's `backend/` dir at compile
time and runs the server there; the UI loads from the bundled `dist/` and talks
to the backend at `http://127.0.0.1:7777`.

## How it works

- **Roles**: planner / implementer / reviewer — any agent in any role, per task.
- **Loop**: plan → (implement → checkpoint commit → review)×N. Reviewer alone
  decides approval via a schema-validated JSON verdict.
- **Guardrails**: never runs on `main`, creates `trinity/<slug>` branch, stashes a
  dirty worktree, per-call timeout, checkpoint commit each iteration.
- **Escalation**: ≥2 consecutive rejections → planner revises the plan.
- **Stop reasons** (always explicit): `approved`, `max_iterations`,
  `plan_rejected`, `agent_error`, `verdict_unparseable`, `no_changes`,
  `cancelled`.

Per-run artifacts land in `<target-project>/.trinity/runs/<id>/`
(`task.md`, `plan.md`, `review-N.json`, `transcript.log`, `status.json`).
Tool-global state lives in `~/.trinity/`.

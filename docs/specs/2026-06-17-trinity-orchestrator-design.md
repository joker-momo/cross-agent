# Trinity — Multi-Agent Orchestrator (Design Spec)

**Date:** 2026-06-17
**Status:** Approved design, pre-implementation
**Author:** brainstormed with Claude (Opus 4.8)

---

## 1. Goal

A standalone, project-agnostic tool that orchestrates three coding-agent CLIs —
**Claude** (`claude`), **Codex** (`codex`), and **Antigravity** (`agy`) — across a
plan → implement → review loop, driven from a local web control center.

You give one task. You pick which agent plays each role (planner / implementer /
reviewer) — fully flexible, any agent in any role, chosen per task. The tool runs
the loop full-auto until the reviewer approves, or it stops and tells you exactly
why.

The tool lives in its own repo. To use it on a project, you point it at that
project's path. It is NOT embedded in any target project.

---

## 2. Roles & flexibility

- Three roles per task: **planner**, **implementer**, **reviewer**.
- Each role is assigned, per task, to any of `{claude, codex, agy}`.
- No fixed mapping. `agy` is not hard-wired to implement. Any agent, any role,
  changeable every task.
- Selected in the web UI before each run (or via CLI flags as backup).

---

## 3. Execution flow

```
New task (from UI: project + request + role assignment)
  │
  ├─ Pre-flight guardrails
  │     • target worktree clean? (else warn, refuse/stash)
  │     • not on main? create branch trinity/<slug>
  │
  ├─ PLAN     → planner reads project rules (AGENTS.md/CLAUDE.md/.agent) + task
  │             → writes plan.md
  │
  ├─ LOOP (max 5 iterations):
  │     IMPLEMENT → implementer reads plan.md → edits code in target project
  │                 → checkpoint commit "wip: iter N"
  │     REVIEW    → reviewer scores → verdict JSON {approved, blocking_issues, ...}
  │       approved == true  → STOP(approved)
  │       approved == false → feed blocking_issues back to implementer (loop)
  │                           ≥2 consecutive fails → escalate to planner
  │                           (planner revises plan.md, then resume loop)
  │
  └─ STOP → always set status.json.stop_reason + surface clear reason in UI
```

Defaults: `max_iter = 5`, `escalate_after = 2`. Both configurable.

---

## 4. Architecture (3 layers)

```
┌─ Web UI (browser, localhost:7777) ────────────────┐
│  • Project picker: add path, list saved projects   │
│  • New task: request text + role pick (3 agents)   │
│  • Live board: plan → iter → review, diff, logs     │
│  • Controls: Run / Stop / Retry                     │
└───────────────┬───────────────────────────────────┘
                │ REST + SSE (real-time event stream)
┌───────────────▼───────────────────────────────────┐
│  Server (FastAPI + uvicorn, M2-native)             │
│  • REST: /projects, /runs, /run/{id}, /run/{id}/stop│
│  • SSE:  /run/{id}/events  (live state + log push)  │
│  • owns run lifecycle + state                       │
└───────────────┬───────────────────────────────────┘
                │ invokes
┌───────────────▼───────────────────────────────────┐
│  Core engine (project-agnostic Python)             │
│  • orchestrator.py — loop: plan→implement→review    │
│  • agents.py       — adapter: claude/codex/agy       │
│  • verdict.py      — parse + validate verdict JSON   │
│  • git.py          — branch, checkpoint, guardrails  │
│  • config.py       — defaults, schema paths          │
│  → runs agent CLIs INSIDE the target project dir     │
└────────────────────────────────────────────────────┘
```

### State & artifacts

- Tool-global state: `~/.trinity/projects.json` (saved project paths),
  `~/.trinity/runs/<id>/` (run index, metadata).
- Per-run artifacts written INTO the target project at
  `<target-project>/.trinity/runs/<id>/`:
  - `task.md`        — original request
  - `plan.md`        — planner output
  - `review-N.json`  — verdict each iteration
  - `transcript.log` — full command + stdout/stderr log
  - `status.json`    — `{state, iteration, roles, stop_reason, branch}`
- `<target-project>/.trinity/` should be gitignored by the target (tool can offer
  to add the entry). The review schema is committed in the Trinity repo.

---

## 5. Agent adapter (`agents.py`)

One interface, three backends. Each agent still reads its own project rules
(AGENTS.md / CLAUDE.md / .agent) so the project's PRIME DIRECTIVE holds in every
role.

| Capability   | claude                        | codex                                   | agy (Antigravity)        |
|--------------|-------------------------------|-----------------------------------------|--------------------------|
| run prompt   | `claude -p`                   | `codex exec`                            | `agy -p --yes`           |
| force JSON   | `--output-format json`        | `--output-schema review.schema.json`    | `--output-format json`*  |
| allow edits  | `--permission-mode acceptEdits` | `--sandbox workspace-write`           | `--yes`                  |
| resume       | `--resume <id>`               | `codex exec resume <id>`                | conversation id          |

\* `agy` JSON output is still stabilizing; known non-TTY stdout drop
(google-antigravity/antigravity-cli#76) — run with `< /dev/null`, capture via
`--output-format json` + file redirect, and validate. Treat unparseable output as
`verdict_unparseable` stop.

Codex's `--output-schema` enforces a JSON verdict, making it the most reliable
reviewer backend.

### Verdict schema (`review.schema.json`)

```json
{
  "approved": false,
  "blocking_issues": ["..."],
  "minor_notes": ["..."],
  "reason": "..."
}
```

Reviewer — not implementer — decides `approved`. Implementer never self-certifies.

---

## 6. Stop reasons (always explicit, never silent)

| stop_reason          | Trigger                                  | Surfaced message                                   |
|----------------------|------------------------------------------|----------------------------------------------------|
| `approved`           | reviewer `approved == true`              | ✓ Done after N iters. Change summary + minor notes |
| `max_iterations`     | 5 iters, still not approved              | ✗ Not met in 5 iters. Last blocking_issues + diff  |
| `plan_rejected`      | escalated to planner ≥2×, still failing  | ✗ Plan repeatedly wrong. Plan + reviewer reason    |
| `agent_error`        | agent crash / timeout / exit ≠ 0         | ✗ <agent> as <role> failed. Verbatim stderr        |
| `verdict_unparseable`| review output not valid per schema       | ✗ Reviewer bad format. Raw output                  |
| `no_changes`         | implementer ran but `git diff` empty     | ✗ Implementer made no edits. Output                |

Every stop writes `status.json.stop_reason` and pushes the reason to the UI.

---

## 7. Full-auto guardrails (quality > speed)

- **Git safety:** each run on a dedicated branch `trinity/<slug>`. Never auto-run
  on `main`. Checkpoint commit after each implement iteration → rollback + visible
  progress.
- **Dirty worktree:** before start, if target worktree is dirty → warn, offer
  stash / refuse. Never mix unrelated user changes into a run.
- **Per-call timeout** (default 20 min) → no infinite hang in full-auto.
- **Reviewer authority:** verdict comes from reviewer only.
- **OpenWolf integration (conditional):** if the target project has `.wolf/`,
  append one line to `.wolf/memory.md` per run; log `agent_error`/fixes to
  `.wolf/buglog.json`. Respect target project rules.

---

## 8. Tech stack

- **Backend / core:** Python 3.11+, FastAPI, uvicorn (M2-native), `subprocess`,
  `jsonschema`, `pydantic`, stdlib (`pathlib`, `dataclasses`, `enum`, `json`).
- **Frontend:** React + Vite + TypeScript + Tailwind + **shadcn/ui**; real-time
  via `EventSource` (SSE).
- No heavy deps; agent CLIs handle their own auth.

---

## 9. CLI (backup control path)

```
trinity --project <path> "request..." \
        -P claude -I antigravity -R codex \
        --max-iter 5 --escalate-after 2 --dry-run
```

`--dry-run` prints the agent commands without executing.

---

## 10. Test plan (TDD, no live agent calls in tests)

- `agents.py` — mock `subprocess.run`; assert correct command + flags per backend.
- `verdict.py` — valid / malformed / missing-field JSON → correct stop_reason.
- `orchestrator.py` — scripted fake agents covering every branch: approve iter 1,
  max_iterations, escalate-to-planner, agent_error, no_changes,
  verdict_unparseable.
- `git.py` — refuse on main; refuse on dirty worktree; branch + checkpoint created.
- Server — REST + SSE contract tests with a fake engine.
- Manual smoke (later): one small real task exercising all three agents.

---

## 11. MVP scope (YAGNI)

**In:** single task at a time per project, web control + monitor, role pick per
task, full loop with guardrails, multi-project picker.

**Out (later):** auth / multi-user, parallel runs, cost/token dashboard, resume of
interrupted runs, queueing.

---

## 12. Open items for the new session

- Confirm repo layout (monorepo `backend/` + `frontend/`, or split).
- Pick package manager (uv for Python; pnpm/npm for frontend).
- Decide port + whether to auto-open browser on launch.
- Verify exact `agy` JSON flag name once CLI is installed locally.
```

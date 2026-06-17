# anatomy.md

> Auto-maintained by OpenWolf. Last scanned: 2026-06-17T06:23:29.400Z
> Files: 32 tracked | Anatomy hits: 0 | Misses: 0

## ./

- `README.md` — Project documentation (~493 tok)

## backend/

- `pyproject.toml` — Multi-agent orchestrator: plan -> implement -> review across claude/codex/agy (~171 tok)

## backend/tests/

- `__init__.py` (~0 tok)
- `test_agents.py` — FakeProc: test_claude_implementer_has_edit_flag, test_claude_reviewer_has_json_flag_no_edit, test_co (~755 tok)
- `test_git.py` — repo, test_slugify, test_preflight_refuses_on_main, test_preflight_refuses_non_repo (~590 tok)
- `test_orchestrator.py` — --- fakes --------------------------------------------------------------- (~1760 tok)
- `test_server.py` — client, test_projects_empty, test_add_project, test_add_nonexistent_project_400 (~828 tok)
- `test_verdict.py` — test_valid_bare_json, test_valid_fenced_json_with_prose, test_missing_field_rejected, test_wrong_typ (~479 tok)

## backend/trinity/

- `__init__.py` — Trinity — multi-agent orchestrator (plan -> implement -> review). (~28 tok)
- `agents.py` — Agent adapter: one interface, three CLI backends (claude / codex / agy). (~937 tok)
- `artifacts.py` — Per-run artifact storage inside the target project (.trinity/runs/<id>/). (~466 tok)
- `cli.py` — Backup control path: run a task from the command line, or launch the server. (~1211 tok)
- `config.py` — Defaults, paths, and role/agent enums. (~514 tok)
- `git.py` — Git guardrails for the target project: branch, checkpoint, safety checks. (~853 tok)
- `orchestrator.py` — The plan -> implement -> review loop. Dependency-injected for testing. (~2819 tok)
- `projects.py` — Saved target-project registry (~/.trinity/projects.json). (~312 tok)
- `prompts.py` — Prompt templates for each role. Agents read project rules themselves. (~682 tok)
- `runmanager.py` — In-process run lifecycle: spawn orchestrator in a thread, bridge events. (~1266 tok)
- `server.py` — FastAPI server: REST control + SSE event stream for the web UI. (~1028 tok)
- `verdict.py` — Parse + validate reviewer verdict JSON against review.schema.json. (~720 tok)

## backend/trinity/schema/

- `review.schema.json` (~219 tok)

## frontend/

- `index.html` — Trinity — Multi-Agent Orchestrator (~90 tok)
- `package.json` — Node.js package manifest (~180 tok)
- `postcss.config.js` (~24 tok)
- `tailwind.config.js` (~176 tok)
- `tsconfig.json` — TypeScript configuration (~161 tok)
- `tsconfig.node.json` (~73 tok)
- `vite.config.ts` — During dev, proxy API calls to the FastAPI backend on :7777. (~143 tok)

## frontend/src/

- `api.ts` — Exports Agent, AGENTS, Roles, RunRecord, api (~395 tok)
- `App.tsx` — ROLE_KEYS (~2998 tok)
- `index.css` — Styles: 4 rules, 9 vars (~153 tok)
- `main.tsx` (~68 tok)

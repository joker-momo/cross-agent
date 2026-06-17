# Cerebrum — Cross-Session Learnings

OpenWolf's value comes from learning across sessions. Update this file whenever
you learn something useful (low bar — when in doubt, add it).

## User Preferences

- Prime directive: correctness + real output quality win over speed/cost.
- Reasoning-tier handshake: begin every reply with `Reasoning tier: <low|medium|high|max> — reason`.
- Roles are flexible per task: any of {claude, codex, agy} can be planner /
  implementer / reviewer.

## Key Learnings

- This is a standalone, project-agnostic tool. It operates on a target project by
  path; it is NOT embedded in any target project.
- Headless agent CLIs: `claude -p` (`--output-format json`), `codex exec`
  (`--output-schema`, `--sandbox workspace-write`), `agy -p --yes`
  (`--output-format json`, known non-TTY stdout drop — google-antigravity/antigravity-cli#76).

## Do-Not-Repeat

_(add dated entries when a mistake is corrected)_

## Decision Log

- 2026-06-17: Loop strategy = hybrid (implement↔review, escalate to planner after
  2 consecutive fails). max_iter=5, full-auto, every stop states an explicit reason.
- 2026-06-17: UI = local web control center (FastAPI + React/Vite/Tailwind/shadcn,
  SSE for live). Full control + monitor.

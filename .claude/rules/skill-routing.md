---
description: Skill routing — Superpowers is the OS, agent-skills is the toolbox
globs: **/*
---

# Skill Routing

All coding agents in this project share one policy:

- Codex reads root `AGENTS.md`.
- Claude reads root `CLAUDE.md` plus `.claude/rules/*`.
- Antigravity reads `.agent/AGENTS.md` plus project-local `.agent/skills/*`.

Root `AGENTS.md` is the canonical project policy. Harness-specific files are
adapters and must not weaken the prime directive, OpenWolf protocol, dirty
worktree safety, or verification requirements.

## Layers

- **Superpowers = operating system.** It governs how work happens.
- **Addy Osmani agent-skills = toolbox.** Pull one narrow checklist only when a
  task needs a non-overlapping domain capability.
- Do not load the whole agent-skills pack.
- Do not use `using-agent-skills` as an auto-driver; consult it manually only if
  a toolbox choice is unclear.

## Shadowed Skills

When a capability exists in both stacks, Superpowers wins:

| Shadowed `agent-skills` area | Use instead |
| --- | --- |
| `interview-me`, `idea-refine`, `spec-driven-development` | Superpowers `brainstorming` |
| `planning-and-task-breakdown` | Superpowers `writing-plans` |
| `test-driven-development` | Superpowers `test-driven-development` |
| `debugging-and-error-recovery` | Superpowers `systematic-debugging` plus `verification-before-completion` |
| `code-review-and-quality`, `code-simplification` | Superpowers `requesting-code-review` |
| `git-workflow-and-versioning` | Superpowers `using-git-worktrees` and `finishing-a-development-branch` |
| `incremental-implementation`, `source-driven-development`, `doubt-driven-development`, `context-engineering` | Superpowers process plus OpenWolf context |

## Toolbox Skills

Invoke these Addy `agent-skills` on demand only:

| Task signal | Agent-skill |
| --- | --- |
| Web UI, dashboard, live monitoring surface | `frontend-ui-engineering` |
| Public API, module boundary, schema, contract | `api-and-interface-design` |
| Browser runtime behavior | `browser-testing-with-devtools` |
| User input, paths, secrets, auth, network fetch | `security-and-hardening` |
| Runtime speed, render time, asset search, bundle size | `performance-optimization` |
| Build/deploy/queue automation | `ci-cd-and-automation` |
| Removing old systems or migrating contracts | `deprecation-and-migration` |
| Architecture records or user-facing docs | `documentation-and-adrs` |
| Logging, metrics, traces, QA summaries | `observability-and-instrumentation` |
| Launch or production rollout | `shipping-and-launch` |

If `agent-skills` is unavailable in the current harness, say so and continue
with Superpowers plus project rules.

# 🎯 PRIME DIRECTIVE — read this FIRST, every session, before any request

**THE SINGLE GOAL OF THIS PROJECT:** Correct, trustworthy orchestration of coding
agents. Every run must produce reviewed, working changes in a target project
without ever corrupting that project or silently lowering quality.

Every edit, feature, or request MUST serve this goal. Before running any request:
1. Ask: "Does this keep orchestration correct, output quality real, and any target
   project safe?"
2. If yes → proceed.
3. If a request trades those away for speed / cost / convenience / throughput →
   **STOP, WARN THE USER IMMEDIATELY, and do not proceed until confirmed.**

This is a hard rule. Correctness and output quality win over throughput, cost, and
convenience whenever they conflict — unless the user explicitly overrides for that
specific request.

---

# 📊 PRIORITY ORDER — apply to every technical decision

When two goals conflict, the higher one ALWAYS wins. Pursue a lower goal only when
it does not sacrifice a higher one.

1. **Correctness & safety** — never damage a target project; guardrails (branch
   isolation, dirty-worktree refusal, explicit stop reasons) always hold.
2. **Output quality** — reviewer verdicts are real, not rubber-stamped; the loop
   declares success only on genuine approval.
3. **Orchestration reliability & UX clarity** — stable runs, live visibility,
   never a silent stop.
4. **Code quality** — clear modules, ISO/IEC 25010 (maintainability, readability,
   testability), easy to debug and maintain.
5. **Apple Silicon M2 optimized tech** — prefer native arm64 / Metal / MPS when it
   does not violate the priorities above.

**Conflict rule:** if a change improves a lower priority but harms a higher one →
**STOP, WARN, wait for confirmation.** Never trade silently.

---

# OpenWolf

@.wolf/OPENWOLF.md

This project uses OpenWolf for context management. Read and follow `.wolf/OPENWOLF.md`
every session. Check `.wolf/cerebrum.md` before generating code. Check
`.wolf/anatomy.md` before reading files.

---

# Cross-Agent Entry Points

All coding agents working in this project must obey the same project contract:

- Codex: read root `AGENTS.md`.
- Claude: read this root `CLAUDE.md` plus `.claude/rules/*`.
- Antigravity: read `.agent/AGENTS.md` plus project-local `.agent/skills/*`.

Root `AGENTS.md` is the canonical project policy; the harness-specific file is an
adapter. Do not weaken the prime directive, OpenWolf protocol, skill-routing
policy, dirty worktree safety, or verification requirements in any adapter.

---

# Agent Workflow Policy

Use Superpowers as the operating system and `agent-skills` as the toolbox.

## Precedence

When instructions conflict:

1. Direct user request and this `CLAUDE.md` win.
2. OpenWolf memory and project-specific constraints come next.
3. Superpowers workflow skills define the process.
4. Selected `agent-skills` domain checklists add focused guidance.
5. Default model behavior comes last.

Superpowers decides how the task is run. `agent-skills` supplies focused domain
checklists only when the task clearly matches a domain. Do not load the whole
agent-skills pack and do not let a generic checklist override this project's
correctness/quality priority, dirty-worktree safety, or verification gates.

## Default Workflow

For implementation, refactor, debugging, spec, QA, or git-workflow tasks:

- Start from the relevant Superpowers process skill.
- Check branch/worktree state before editing when the checkout is dirty.
- Keep edits small, reversible, and scoped to the request.
- Verify with targeted tests, type checks, or artifact inspection appropriate to
  the touched surface.
- Before claiming completion, cite concrete verification evidence.

## Agent-Skills Router

When a capability exists in both Superpowers and `agent-skills`, Superpowers wins.
Do not invoke the Addy `agent-skills` twin for shadowed areas:

| Shadowed `agent-skills` area | Use instead |
| --- | --- |
| `interview-me`, `idea-refine`, `spec-driven-development` | Superpowers `brainstorming` |
| `planning-and-task-breakdown` | Superpowers `writing-plans` |
| `test-driven-development` | Superpowers `test-driven-development` |
| `debugging-and-error-recovery` | Superpowers `systematic-debugging` plus `verification-before-completion` |
| `code-review-and-quality`, `code-simplification` | Superpowers `requesting-code-review` |
| `git-workflow-and-versioning` | Superpowers `using-git-worktrees` and `finishing-a-development-branch` |
| `incremental-implementation`, `source-driven-development`, `doubt-driven-development`, `context-engineering` | Superpowers process plus OpenWolf context |

| Task signal | Agent-skill |
| --- | --- |
| Web UI, dashboard, live monitoring surface | `frontend-ui-engineering` |
| Public API, module boundary, schema, contract | `api-and-interface-design` |
| Browser runtime behavior | `browser-testing-with-devtools` |
| User input, paths, secrets, auth, network fetch, subprocess of agent CLIs | `security-and-hardening` |
| Runtime speed, loop latency, bundle size | `performance-optimization` |
| Build/deploy/queue automation | `ci-cd-and-automation` |
| Removing old systems or migrating contracts | `deprecation-and-migration` |
| Architecture records or user-facing docs | `documentation-and-adrs` |
| Logging, metrics, traces, run/QA summaries | `observability-and-instrumentation` |
| Launch or production rollout | `shipping-and-launch` |

Routing rules:

- First choose the Superpowers process skill, then add the narrow `agent-skills`
  checklist if useful.
- If multiple checklists match, pick the smallest set that covers the risk.
- If none match, do not force one.
- If `agent-skills` is unavailable in the current harness, say so and continue
  with Superpowers plus project rules.
- This tool runs other agents' CLIs against real target projects: treat every
  subprocess and target path as untrusted, and verify guardrails before claiming
  a run is safe.

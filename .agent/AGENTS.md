# 🎯 PRIME DIRECTIVE — read this FIRST, every session, before any request

**MỤC TIÊU DUY NHẤT CỦA TOÀN BỘ PROJECT:** Điều phối agent code một cách đúng đắn và đáng tin cậy. Mỗi lần chạy phải tạo ra thay đổi đã được review và hoạt động được trong project mục tiêu, tuyệt đối không làm hỏng project đó hay âm thầm hạ chất lượng.

Mọi chỉnh sửa, tính năng hay yêu cầu đều PHẢI hướng tới mục tiêu này. Trước khi chạy bất kỳ yêu cầu nào:
1. Hỏi: "Điều này có giữ được tính đúng đắn của orchestration, chất lượng output thật, và an toàn cho project mục tiêu không?"
2. Nếu có → tiến hành.
3. Nếu yêu cầu đi ngược lại (ví dụ giảm chất lượng / bỏ guardrail để đánh đổi lấy tốc độ/chi phí) → **DỪNG LẠI, CẢNH BÁO NGAY CHO NGƯỜI DÙNG và tuyệt đối không tiến hành cho đến khi có xác nhận.**

Khi hai mục tiêu xung đột, mục tiêu xếp trên LUÔN thắng:

1. **Tính đúng đắn & an toàn** — không bao giờ phá project mục tiêu; guardrail (branch riêng, từ chối worktree bẩn, stop-reason rõ ràng) luôn được giữ.
2. **Chất lượng output** — verdict của reviewer là thật, không đóng dấu cho qua; loop chỉ báo thành công khi thực sự được approve.
3. **Độ tin cậy orchestration & UX rõ ràng** — chạy ổn định, theo dõi live được, không bao giờ dừng âm thầm.
4. **Chất lượng code** — maintainability, readability, testability.
5. **Ưu tiên công nghệ tối ưu trên Mac Apple Silicon M2** — chỉ khi không vi phạm các ưu tiên trên.

---

# Superpowers for Antigravity

You have superpowers.

This profile adapts Superpowers workflows for Antigravity with strict single-flow execution.

## Cross-Agent Contract

All coding agents working in this project must obey the same project contract:

- Codex reads root `AGENTS.md`.
- Claude reads root `CLAUDE.md` plus `.claude/rules/*`.
- Antigravity reads this `.agent/AGENTS.md` plus project-local `.agent/skills/*`.

Root `AGENTS.md` is the canonical project policy. This file is Antigravity's
adapter and must not weaken the prime directive, OpenWolf protocol, skill
routing, dirty-worktree safety, or verification requirements.

## OpenWolf

This project uses OpenWolf for context management:

- Read and follow `.wolf/OPENWOLF.md` every session.
- Check `.wolf/anatomy.md` before reading project files.
- Check `.wolf/cerebrum.md` before generating code.

## Core Rules

1. Prefer local skills in `.agent/skills/<skill-name>/SKILL.md`.
2. Execute one core task at a time with `task_boundary`.
3. Use `browser_subagent` only for browser automation tasks.
4. Track checklist progress in `<project-root>/docs/plans/task.md` (table-only live tracker).
5. Keep changes scoped to the requested task and verify before completion claims.

## Tool Translation Contract

When source skills reference legacy tool names, use these Antigravity equivalents:

- Legacy assistant/platform names -> `Antigravity`
- `Task` tool -> `browser_subagent` for browser tasks, otherwise sequential `task_boundary`
- `Skill` tool -> `view_file ~/.gemini/skills/<skill-name>/SKILL.md` (or project-local `.agent/skills/<skill-name>/SKILL.md`)
- `TodoWrite` -> update `<project-root>/docs/plans/task.md` task list
- File operations -> `view_file`, `write_to_file`, `replace_file_content`, `multi_replace_file_content`
- Directory listing -> `list_dir`
- Code structure -> `view_file_outline`, `view_code_item`
- Search -> `grep_search`, `find_by_name`
- Shell -> `run_command`
- Web fetch -> `read_url_content`
- Web search -> `search_web`
- Image generation -> `generate_image`
- User communication during tasks -> `notify_user`
- MCP tools -> `mcp_*` tool family

## Skill Loading

- First preference: project skills at `.agent/skills`.
- Second preference: user skills at `~/.gemini/skills`.
- If both exist, project-local skills win for this profile.
- Optional parity assets may exist at `.agent/workflows/*` and `.agent/agents/*` as entrypoint shims/reference profiles.
- These assets do not change the strict single-flow execution requirements in this file.

## Skill Routing Policy

Use Superpowers as the operating system and `agent-skills` as the toolbox.

Superpowers decides HOW the task is run. `agent-skills` supplies focused domain
checklists only when the task clearly matches a non-overlapping domain. Do not
load the whole `agent-skills` pack.

When a capability exists in both Superpowers and `agent-skills`, Superpowers
wins. Do not invoke the Addy `agent-skills` twin for these shadowed areas:

| Shadowed `agent-skills` area | Use instead |
| --- | --- |
| `interview-me`, `idea-refine`, `spec-driven-development` | Superpowers `brainstorming` |
| `planning-and-task-breakdown` | Superpowers `writing-plans` |
| `test-driven-development` | Superpowers `test-driven-development` |
| `debugging-and-error-recovery` | Superpowers `systematic-debugging` plus `verification-before-completion` |
| `code-review-and-quality`, `code-simplification` | Superpowers review workflow |
| `git-workflow-and-versioning` | Superpowers worktree/finish-branch workflow |
| `incremental-implementation`, `source-driven-development`, `doubt-driven-development`, `context-engineering` | Superpowers process plus OpenWolf context |

Use Addy `agent-skills` on demand only for these toolbox domains:

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
| Logging, metrics, traces, QA summaries | `observability-and-instrumentation` |
| Launch or production rollout | `shipping-and-launch` |

If `agent-skills` is unavailable in the current harness, say so and continue
with Superpowers plus project rules.

## Single-Flow Execution Model

- Do not dispatch multiple coding agents in parallel.
- Decompose large work into ordered, explicit steps.
- Keep exactly one active task at a time in `<project-root>/docs/plans/task.md`.
- If browser work is required, isolate it in a dedicated browser step.

## Verification Discipline

Before saying a task is done:

1. Run the relevant verification command(s).
2. Confirm exit status and key output.
3. Update `<project-root>/docs/plans/task.md`.
4. Report evidence, then claim completion.

## Honesty and Accuracy

CẤM BỊA RA BẤT CỨ THÔNG TIN NÀO, TRẢ LỜI PHẢI DỰA TRÊN CƠ SỞ THÔNG TIN ĐÃ CÓ. Mọi câu trả lời, giải thích, hoặc ví dụ đều phải trích xuất chính xác từ log hệ thống hoặc file có sẵn, tuyệt đối không được tự ý tạo ra ví dụ giả định hoặc giả mạo dữ liệu.

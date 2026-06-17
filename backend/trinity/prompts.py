"""Prompt templates for each role. Agents read project rules themselves."""

from __future__ import annotations

_RULES_NOTE = (
    "First read this project's rules (AGENTS.md, CLAUDE.md, and/or .agent/) "
    "and obey them as the PRIME DIRECTIVE."
)


def planner_prompt(task: str, plan_path: str) -> str:
    return (
        f"{_RULES_NOTE}\n\n"
        "You are the PLANNER. Produce a concrete, step-by-step implementation "
        "plan for the task below. Be specific about files to change and the "
        "order of work. Keep it tight — no code yet.\n\n"
        f"Write the plan to `{plan_path}` (overwrite if it exists).\n\n"
        f"TASK:\n{task}\n"
    )


def replan_prompt(task: str, plan_path: str, blocking_issues: list[str]) -> str:
    issues = "\n".join(f"- {i}" for i in blocking_issues)
    return (
        f"{_RULES_NOTE}\n\n"
        "You are the PLANNER. The previous plan led to implementations the "
        "reviewer repeatedly rejected. Revise the plan to address these "
        "recurring blocking issues:\n"
        f"{issues}\n\n"
        f"Rewrite `{plan_path}` with the improved plan.\n\n"
        f"ORIGINAL TASK:\n{task}\n"
    )


def implementer_prompt(plan_path: str, feedback: list[str] | None = None) -> str:
    base = (
        f"{_RULES_NOTE}\n\n"
        "You are the IMPLEMENTER. Read the plan at "
        f"`{plan_path}` and implement it by editing code in this project. "
        "Make all necessary changes. Do not self-certify — a separate "
        "reviewer will judge your work."
    )
    if feedback:
        notes = "\n".join(f"- {i}" for i in feedback)
        base += (
            "\n\nThe reviewer rejected the last iteration. Fix these "
            f"blocking issues:\n{notes}"
        )
    return base + "\n"


def reviewer_prompt(task: str, diff: str) -> str:
    return (
        f"{_RULES_NOTE}\n\n"
        "You are the REVIEWER. Judge whether the implementation below fully and "
        "correctly satisfies the task and the project rules. You alone decide "
        "approval.\n\n"
        "Respond with ONLY a JSON object matching this shape:\n"
        '{"approved": <bool>, "blocking_issues": [<str>], '
        '"minor_notes": [<str>], "reason": <str>}\n\n'
        "Set approved=true only if there are no blocking issues.\n\n"
        f"TASK:\n{task}\n\n"
        f"DIFF UNDER REVIEW:\n{diff}\n"
    )

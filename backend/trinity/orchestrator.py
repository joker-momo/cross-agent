"""The plan -> implement -> review loop. Dependency-injected for testing."""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Protocol

from . import agents as agents_mod
from . import git as git_mod
from . import prompts
from .agents import AgentError, AgentResult
from .artifacts import RunArtifacts, new_run_id
from .config import Agent, Role, Roles, RunConfig, State, StopReason
from .verdict import Verdict, VerdictUnparseable, parse_verdict


@dataclass
class Event:
    type: str  # e.g. "state", "log", "verdict", "stop"
    data: dict = field(default_factory=dict)


EmitFn = Callable[[Event], None]
InvokeFn = Callable[..., AgentResult]


class GitOps(Protocol):
    def preflight(self, cwd: Path) -> None: ...
    def is_dirty(self, cwd: Path) -> bool: ...
    def stash(self, cwd: Path) -> None: ...
    def create_branch(self, cwd: Path, slug: str) -> str: ...
    def slugify(self, text: str) -> str: ...
    def has_changes(self, cwd: Path) -> bool: ...
    def checkpoint(self, cwd: Path, message: str) -> str | None: ...
    def diff(self, cwd: Path) -> str: ...


class RealGit:
    """Default GitOps backed by the real git module."""

    def preflight(self, cwd): return git_mod.preflight(cwd)
    def is_dirty(self, cwd): return git_mod.is_dirty(cwd)
    def stash(self, cwd): return git_mod.stash(cwd)
    def create_branch(self, cwd, slug): return git_mod.create_branch(cwd, slug)
    def slugify(self, text): return git_mod.slugify(text)
    def has_changes(self, cwd): return git_mod.has_changes(cwd)
    def checkpoint(self, cwd, message): return git_mod.checkpoint(cwd, message)
    def diff(self, cwd): return git_mod.diff(cwd)


@dataclass
class RunResult:
    run_id: str
    branch: str | None
    stop_reason: StopReason
    iterations: int
    last_verdict: Verdict | None
    message: str


def _default_invoke(
    agent: Agent, role: Role, prompt: str, *, cwd: Path, timeout_s: int
) -> AgentResult:
    return agents_mod.run_agent(agent, role, prompt, cwd=cwd, timeout_s=timeout_s)


class Orchestrator:
    def __init__(
        self,
        *,
        invoke: InvokeFn = _default_invoke,
        git: GitOps | None = None,
        emit: EmitFn | None = None,
        config: RunConfig | None = None,
        cancel: Callable[[], bool] | None = None,
    ):
        self.invoke = invoke
        self.git = git or RealGit()
        self.emit = emit or (lambda e: None)
        self.config = config or RunConfig()
        self.cancel = cancel or (lambda: False)

    # --- helpers ---
    def _emit(self, type_: str, **data) -> None:
        self.emit(Event(type=type_, data=data))

    def _set_state(self, art: RunArtifacts, roles: Roles, state: State,
                   iteration: int, branch: str | None,
                   stop_reason: StopReason | None = None) -> None:
        status = {
            "run_id": art.run_id,
            "state": state.value,
            "iteration": iteration,
            "roles": roles.as_dict(),
            "branch": branch,
            "stop_reason": stop_reason.value if stop_reason else None,
        }
        art.write_status(status)
        self._emit("state", **status)

    def _call(self, art, agent: Agent, role: Role, prompt: str, cwd: Path) -> AgentResult:
        res = self.invoke(agent, role, prompt, cwd=cwd,
                          timeout_s=self.config.call_timeout_s)
        art.append_transcript(f"$ {' '.join(res.command)}")
        if res.stdout:
            art.append_transcript(res.stdout)
        if res.stderr:
            art.append_transcript("[stderr] " + res.stderr)
        return res

    # --- main entry ---
    def run(self, project_dir: Path, task: str, roles: Roles,
            run_id: str | None = None) -> RunResult:
        project_dir = Path(project_dir)
        run_id = run_id or new_run_id()
        art = RunArtifacts(project_dir, run_id)
        art.ensure()
        art.task_md.write_text(task)

        branch: str | None = None
        # --- pre-flight guardrails ---
        self.git.preflight(project_dir)
        if self.git.is_dirty(project_dir):
            self.git.stash(project_dir)
            self._emit("log", message="stashed dirty worktree before run")
        slug = self.git.slugify(task)
        branch = self.git.create_branch(project_dir, slug)
        self._emit("log", message=f"created branch {branch}")

        return self._loop(art, project_dir, task, roles, branch)

    def _loop(self, art, project_dir, task, roles, branch) -> RunResult:
        cfg = self.config

        # --- PLAN ---
        self._set_state(art, roles, State.PLANNING, 0, branch)
        plan_rel = str(art.plan_md.relative_to(project_dir))
        try:
            self._call(art, roles.planner, Role.PLANNER,
                       prompts.planner_prompt(task, plan_rel), project_dir)
        except AgentError as e:
            return self._stop(art, roles, branch, 0, StopReason.AGENT_ERROR,
                              str(e), None)

        consecutive_fails = 0
        escalations = 0
        last_verdict: Verdict | None = None

        for iteration in range(1, cfg.max_iter + 1):
            if self.cancel():
                return self._stop(art, roles, branch, iteration - 1,
                                  StopReason.CANCELLED, "cancelled by user",
                                  last_verdict)
            # --- IMPLEMENT ---
            self._set_state(art, roles, State.IMPLEMENTING, iteration, branch)
            feedback = last_verdict.blocking_issues if last_verdict else None
            try:
                self._call(art, roles.implementer, Role.IMPLEMENTER,
                           prompts.implementer_prompt(plan_rel, feedback),
                           project_dir)
            except AgentError as e:
                return self._stop(art, roles, branch, iteration,
                                  StopReason.AGENT_ERROR, str(e), last_verdict)

            if not self.git.has_changes(project_dir):
                return self._stop(art, roles, branch, iteration,
                                  StopReason.NO_CHANGES,
                                  "implementer produced no edits", last_verdict)

            diff = self.git.diff(project_dir)
            sha = self.git.checkpoint(project_dir, f"wip: iter {iteration}")
            self._emit("log", message=f"checkpoint {sha} for iter {iteration}")

            # --- REVIEW ---
            self._set_state(art, roles, State.REVIEWING, iteration, branch)
            try:
                res = self._call(art, roles.reviewer, Role.REVIEWER,
                                 prompts.reviewer_prompt(task, diff), project_dir)
            except AgentError as e:
                return self._stop(art, roles, branch, iteration,
                                  StopReason.AGENT_ERROR, str(e), last_verdict)

            try:
                verdict = parse_verdict(res.stdout)
            except VerdictUnparseable as e:
                art.append_transcript(f"[verdict_unparseable] {e}")
                return self._stop(art, roles, branch, iteration,
                                  StopReason.VERDICT_UNPARSEABLE,
                                  f"reviewer output invalid: {e}", last_verdict)

            art.write_review(iteration, verdict.as_dict())
            last_verdict = verdict
            self._emit("verdict", iteration=iteration, **verdict.as_dict())

            if verdict.approved:
                return self._stop(art, roles, branch, iteration,
                                  StopReason.APPROVED,
                                  f"approved after {iteration} iteration(s)",
                                  verdict, state=State.DONE)

            consecutive_fails += 1
            if (consecutive_fails >= cfg.escalate_after
                    and iteration < cfg.max_iter):
                # --- ESCALATE: planner revises plan, reset fail counter ---
                self._set_state(art, roles, State.PLANNING, iteration, branch)
                self._emit("log", message="escalating to planner")
                try:
                    self._call(art, roles.planner, Role.PLANNER,
                               prompts.replan_prompt(task, plan_rel,
                                                     verdict.blocking_issues),
                               project_dir)
                except AgentError as e:
                    return self._stop(art, roles, branch, iteration,
                                      StopReason.AGENT_ERROR, str(e), verdict)
                consecutive_fails = 0
                escalations += 1

        # Loop exhausted. If the plan was escalated >=2x and still failing,
        # the plan itself is the problem, not the implementation.
        if escalations >= cfg.escalate_after:
            return self._stop(art, roles, branch, cfg.max_iter,
                              StopReason.PLAN_REJECTED,
                              f"plan repeatedly wrong after {escalations} "
                              "re-plans", last_verdict)
        return self._stop(art, roles, branch, cfg.max_iter,
                          StopReason.MAX_ITERATIONS,
                          f"not approved in {cfg.max_iter} iterations",
                          last_verdict)

    def _stop(self, art, roles, branch, iteration, reason: StopReason,
              message: str, verdict, state: State = State.STOPPED) -> RunResult:
        self._set_state(art, roles, state, iteration, branch, reason)
        self._emit("stop", stop_reason=reason.value, message=message)
        return RunResult(
            run_id=art.run_id,
            branch=branch,
            stop_reason=reason,
            iterations=iteration,
            last_verdict=verdict,
            message=message,
        )

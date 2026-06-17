"""Backup control path: run a task from the command line, or launch the server."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from .agents import build_command
from .config import (DEFAULT_HOST, DEFAULT_PORT, Agent, Role, Roles, RunConfig)
from .orchestrator import Event, Orchestrator
from .prompts import implementer_prompt, planner_prompt, reviewer_prompt

_ALIASES = {
    "claude": Agent.CLAUDE,
    "codex": Agent.CODEX,
    "agy": Agent.AGY,
    "antigravity": Agent.AGY,
}


def _agent(name: str) -> Agent:
    try:
        return _ALIASES[name.lower()]
    except KeyError:
        raise argparse.ArgumentTypeError(
            f"unknown agent '{name}'; pick one of {sorted(_ALIASES)}"
        )


def _print_event(e: Event) -> None:
    if e.type == "state":
        print(f"[{e.data.get('state')}] iter={e.data.get('iteration')}")
    elif e.type == "verdict":
        ok = "APPROVED" if e.data.get("approved") else "rejected"
        print(f"  review iter {e.data.get('iteration')}: {ok} — "
              f"{e.data.get('reason')}")
    elif e.type == "log":
        print(f"  · {e.data.get('message')}")
    elif e.type == "stop":
        print(f"== STOP: {e.data.get('stop_reason')} — {e.data.get('message')}")


def _dry_run(project: Path, task: str, roles: Roles) -> int:
    plan_rel = ".trinity/runs/<id>/plan.md"
    print(f"# project: {project}")
    print(f"# task:    {task}")
    print(f"# roles:   {roles.as_dict()}\n")
    print("PLAN:    ", " ".join(
        build_command(roles.planner, Role.PLANNER,
                      planner_prompt(task, plan_rel))[:2]), "...")
    print("IMPLEMENT:", " ".join(
        build_command(roles.implementer, Role.IMPLEMENTER,
                      implementer_prompt(plan_rel))[:2]), "...")
    print("REVIEW:  ", " ".join(
        build_command(roles.reviewer, Role.REVIEWER,
                      reviewer_prompt(task, "<diff>"))[:2]), "...")
    return 0


def build_run_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="trinity",
                                description="Multi-agent orchestrator "
                                            "(use `trinity serve` for the UI)")
    p.add_argument("request", nargs="?", help="the task request text")
    p.add_argument("--project", type=Path, help="target project path")
    p.add_argument("-P", "--planner", type=_agent, default="claude")
    p.add_argument("-I", "--implementer", type=_agent, default="agy")
    p.add_argument("-R", "--reviewer", type=_agent, default="codex")
    p.add_argument("--max-iter", type=int, default=5)
    p.add_argument("--escalate-after", type=int, default=2)
    p.add_argument("--dry-run", action="store_true")
    return p


def build_serve_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="trinity serve",
                                description="launch the web control center")
    p.add_argument("--host", default=DEFAULT_HOST)
    p.add_argument("--port", type=int, default=DEFAULT_PORT)
    p.add_argument("--no-open", action="store_true",
                   help="do not auto-open the browser")
    return p


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)

    if argv and argv[0] == "serve":
        sargs = build_serve_parser().parse_args(argv[1:])
        from .server import serve
        serve(host=sargs.host, port=sargs.port, open_browser=not sargs.no_open)
        return 0

    args = build_run_parser().parse_args(argv)

    if not args.request or not args.project:
        print("error: provide a request and --project <path> "
              "(or use `trinity serve`)", file=sys.stderr)
        return 2

    roles = Roles(planner=args.planner, implementer=args.implementer,
                  reviewer=args.reviewer)

    if args.dry_run:
        return _dry_run(args.project, args.request, roles)

    cfg = RunConfig(max_iter=args.max_iter, escalate_after=args.escalate_after)
    orch = Orchestrator(emit=_print_event, config=cfg)
    res = orch.run(args.project, args.request, roles)
    return 0 if res.stop_reason.value == "approved" else 1


if __name__ == "__main__":
    raise SystemExit(main())

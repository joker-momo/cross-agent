"""Agent CLI connectivity + account info for the UI status panel.

Account identity and "quota" come from each CLI's own on-disk config — no
agent CLI exposes a precise remaining-quota number, so we surface the real
hints the config does carry (plan/billing type, reset date, credit state)
rather than inventing a figure.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path

from .config import Agent

_VERSION_ARGS: dict[Agent, list[str]] = {
    Agent.CLAUDE: ["--version"],
    Agent.CODEX: ["--version"],
    Agent.AGY: ["--version"],
}

_CLAUDE_CONFIG = Path.home() / ".claude.json"
_CODEX_HOME = Path(os.environ.get("CODEX_HOME") or Path.home() / ".codex")


@dataclass
class AgentStatus:
    agent: str
    installed: bool
    version: str = ""
    status: str = "missing"  # missing | ready | error
    detail: str = ""
    account: str = ""        # email / identity, "" if unknown
    plan: str = ""           # billing/plan type
    quota_hint: str = ""     # honest config-derived hint, not an exact number
    quota_remaining: str = "" # UI-facing quota label; best-effort only
    can_switch: bool = False # whether Trinity can spawn a login flow

    def as_dict(self) -> dict:
        return {
            "agent": self.agent,
            "installed": self.installed,
            "version": self.version,
            "status": self.status,
            "detail": self.detail,
            "account": self.account,
            "plan": self.plan,
            "quota_hint": self.quota_hint,
            "quota_remaining": self.quota_remaining or self.quota_hint,
            "can_switch": self.can_switch,
        }


def _claude_account() -> dict:
    """Read account + quota hints from ~/.claude.json. All fields best-effort."""
    try:
        d = json.loads(_CLAUDE_CONFIG.read_text())
    except (OSError, json.JSONDecodeError):
        return {}
    oa = d.get("oauthAccount") or {}
    hints: list[str] = []
    gb = (d.get("cachedGrowthBookFeatures") or {}).get(
        "tengu_saffron_lattice"
    ) or {}
    reset = gb.get("planLimitsEndDate")
    if reset:
        hints.append(f"plan resets {reset}")
    reason = d.get("cachedExtraUsageDisabledReason")
    if reason:
        hints.append(str(reason).replace("_", " "))
    elif oa.get("hasExtraUsageEnabled"):
        hints.append("extra usage on")
    return {
        "account": oa.get("emailAddress", ""),
        "plan": oa.get("billingType", ""),
        "quota_hint": "; ".join(hints),
    }


def _read_json(path: Path) -> dict:
    try:
        data = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return {}
    return data if isinstance(data, dict) else {}


def _codex_account(config_dir: Path | None = None) -> dict:
    config_dir = config_dir or _CODEX_HOME
    auth = _read_json(config_dir / "auth.json")
    tokens = auth.get("tokens") or {}
    user = auth.get("user") or auth.get("account") or {}
    account = (
        user.get("email")
        or auth.get("email")
        or tokens.get("account_id")
        or auth.get("account_id")
        or ""
    )
    quota = _latest_codex_quota(config_dir / "sessions")
    return {
        "account": account,
        "plan": quota.get("plan", ""),
        "quota_hint": quota.get("quota_hint", ""),
        "quota_remaining": quota.get("quota_remaining", ""),
    }


def _latest_codex_quota(sessions_dir: Path) -> dict:
    files = sorted(
        sessions_dir.rglob("*.jsonl"),
        key=lambda p: p.stat().st_mtime if p.exists() else 0,
        reverse=True,
    )[:20]
    for path in files:
        try:
            lines = path.read_text(errors="ignore").splitlines()
        except OSError:
            continue
        for line in reversed(lines):
            try:
                value = json.loads(line)
            except json.JSONDecodeError:
                continue
            limits = value.get("rate_limits") or value.get("rate_limit")
            if isinstance(limits, dict):
                quota = _quota_from_codex_rate_limits(limits)
                if quota:
                    return quota
    return {}


def _quota_from_codex_rate_limits(limits: dict) -> dict:
    labels: list[str] = []
    resets: list[str] = []
    for key in ("primary_window", "secondary_window"):
        window = limits.get(key)
        if not isinstance(window, dict):
            continue
        used = window.get("used_percent")
        if not isinstance(used, int | float):
            continue
        seconds = window.get("limit_window_seconds") or 0
        label = "weekly" if isinstance(seconds, int | float) and seconds >= 86_400 else "5h"
        remaining = max(0, min(100, round(100 - float(used))))
        labels.append(f"{label} {remaining}% left")
        reset = window.get("reset_at")
        if reset:
            resets.append(f"{label} reset {reset}")
    if not labels:
        return {}
    return {
        "quota_remaining": "; ".join(labels),
        "quota_hint": "; ".join(resets),
    }


def _attach_account(agent: Agent, st: AgentStatus) -> AgentStatus:
    if agent is Agent.CLAUDE:
        acc = _claude_account()
        st.account = acc.get("account", "")
        st.plan = acc.get("plan", "")
        st.quota_hint = acc.get("quota_hint", "")
        st.quota_remaining = st.quota_hint
        st.can_switch = True  # claude auth login/logout
    elif agent is Agent.CODEX:
        acc = _codex_account()
        st.account = acc.get("account", "")
        st.plan = acc.get("plan", "")
        st.quota_hint = acc.get("quota_hint", "")
        st.quota_remaining = acc.get("quota_remaining", "")
        st.can_switch = True  # codex login/logout
    # agy: no stable account/quota source yet.
    return st


def check_agent(agent: Agent, *, timeout_s: int = 8) -> AgentStatus:
    path = shutil.which(agent.value)
    if not path:
        return AgentStatus(agent.value, installed=False, status="missing",
                           detail="not found on PATH")
    try:
        proc = subprocess.run(
            [agent.value, *_VERSION_ARGS[agent]],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=timeout_s,
        )
    except subprocess.TimeoutExpired:
        return AgentStatus(agent.value, installed=True, status="error",
                           detail=f"version check timed out ({timeout_s}s)")
    except OSError as e:
        return AgentStatus(agent.value, installed=True, status="error",
                           detail=str(e))

    lines = (proc.stdout or proc.stderr or "").strip().splitlines()
    ver = lines[0] if lines else ""
    st = AgentStatus(
        agent.value, installed=True, version=ver,
        status="ready" if proc.returncode == 0 else "error",
        detail="" if proc.returncode == 0 else (proc.stderr or "").strip()[:200],
    )
    return _attach_account(agent, st)


def check_all(timeout_s: int = 8) -> list[dict]:
    return [check_agent(a, timeout_s=timeout_s).as_dict() for a in Agent]


# --- account switching --------------------------------------------------

_SWITCH_CMDS: dict[Agent, dict[str, str]] = {
    Agent.CLAUDE: {
        "login": "claude auth login",
        "logout": "claude auth logout",
    },
    Agent.CODEX: {
        "login": "codex login",
        "logout": "codex logout",
    },
}


class SwitchError(RuntimeError):
    pass


def switch_account(agent: Agent, action: str) -> str:
    """Open a Terminal window running the agent's login/logout flow (macOS).

    Interactive OAuth can't run headless, so we hand it to Terminal where the
    user completes it. Returns the command that was launched.
    """
    cmds = _SWITCH_CMDS.get(agent)
    if not cmds:
        raise SwitchError(f"{agent.value} has no supported switch flow")
    cmd = cmds.get(action)
    if not cmd:
        raise SwitchError(f"unknown action '{action}' for {agent.value}")

    # AppleScript to open Terminal and run the command.
    script = (
        f'tell application "Terminal" to do script "{cmd}"\n'
        'tell application "Terminal" to activate'
    )
    try:
        subprocess.run(["osascript", "-e", script], check=True,
                       capture_output=True, text=True, timeout=15)
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired,
            OSError) as e:
        raise SwitchError(f"failed to launch Terminal: {e}") from e
    return cmd

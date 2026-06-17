"""Parse + validate reviewer verdict JSON against review.schema.json."""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from functools import lru_cache

from jsonschema import Draft202012Validator

from .config import REVIEW_SCHEMA_PATH


class VerdictUnparseable(ValueError):
    """Raised when reviewer output is not valid per the verdict schema."""

    def __init__(self, message: str, raw: str):
        super().__init__(message)
        self.raw = raw


@dataclass
class Verdict:
    approved: bool
    blocking_issues: list[str] = field(default_factory=list)
    minor_notes: list[str] = field(default_factory=list)
    reason: str = ""

    def as_dict(self) -> dict:
        return {
            "approved": self.approved,
            "blocking_issues": list(self.blocking_issues),
            "minor_notes": list(self.minor_notes),
            "reason": self.reason,
        }


@lru_cache(maxsize=1)
def _validator() -> Draft202012Validator:
    schema = json.loads(REVIEW_SCHEMA_PATH.read_text())
    return Draft202012Validator(schema)


# Matches a ```json ... ``` fenced block or a bare {...} object.
_FENCE_RE = re.compile(r"```(?:json)?\s*(\{.*?\})\s*```", re.DOTALL)


def _extract_json(raw: str) -> str:
    """Pull the JSON object out of agent output that may include prose/fences."""
    stripped = raw.strip()
    if not stripped:
        raise VerdictUnparseable("empty reviewer output", raw)

    m = _FENCE_RE.search(raw)
    if m:
        return m.group(1)

    # Fall back to the first balanced {...} span.
    start = stripped.find("{")
    end = stripped.rfind("}")
    if start == -1 or end == -1 or end < start:
        raise VerdictUnparseable("no JSON object found in reviewer output", raw)
    return stripped[start : end + 1]


def parse_verdict(raw: str) -> Verdict:
    """Parse reviewer output into a validated Verdict or raise VerdictUnparseable."""
    candidate = _extract_json(raw)
    try:
        data = json.loads(candidate)
    except json.JSONDecodeError as e:
        raise VerdictUnparseable(f"invalid JSON: {e}", raw) from e

    errors = sorted(_validator().iter_errors(data), key=lambda e: e.path)
    if errors:
        msg = "; ".join(e.message for e in errors)
        raise VerdictUnparseable(f"schema violation: {msg}", raw)

    return Verdict(
        approved=data["approved"],
        blocking_issues=data["blocking_issues"],
        minor_notes=data["minor_notes"],
        reason=data["reason"],
    )

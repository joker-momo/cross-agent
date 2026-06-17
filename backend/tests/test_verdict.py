import pytest

from trinity.verdict import VerdictUnparseable, parse_verdict


def test_valid_bare_json():
    raw = '{"approved": true, "blocking_issues": [], "minor_notes": ["nit"], "reason": "ok"}'
    v = parse_verdict(raw)
    assert v.approved is True
    assert v.minor_notes == ["nit"]
    assert v.reason == "ok"


def test_valid_fenced_json_with_prose():
    raw = (
        "Here is my review.\n"
        "```json\n"
        '{"approved": false, "blocking_issues": ["bug in auth"], '
        '"minor_notes": [], "reason": "not done"}\n'
        "```\n"
        "Hope that helps."
    )
    v = parse_verdict(raw)
    assert v.approved is False
    assert v.blocking_issues == ["bug in auth"]


def test_missing_field_rejected():
    raw = '{"approved": true, "blocking_issues": [], "reason": "x"}'
    with pytest.raises(VerdictUnparseable):
        parse_verdict(raw)


def test_wrong_type_rejected():
    raw = '{"approved": "yes", "blocking_issues": [], "minor_notes": [], "reason": "x"}'
    with pytest.raises(VerdictUnparseable):
        parse_verdict(raw)


def test_extra_property_rejected():
    raw = ('{"approved": true, "blocking_issues": [], "minor_notes": [], '
           '"reason": "x", "score": 9}')
    with pytest.raises(VerdictUnparseable):
        parse_verdict(raw)


def test_not_json_at_all():
    with pytest.raises(VerdictUnparseable):
        parse_verdict("the code looks fine to me, ship it")


def test_empty_output():
    with pytest.raises(VerdictUnparseable):
        parse_verdict("   ")


def test_malformed_json():
    with pytest.raises(VerdictUnparseable):
        parse_verdict('{"approved": true, "blocking_issues": [,]}')

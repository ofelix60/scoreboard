from logging_setup import redact_forwarded_for


def test_every_hop_in_forwarded_for_is_redacted():
    assert redact_forwarded_for("203.0.113.7, 10.0.0.5") == "203.0.113.x, 10.0.0.x"


def test_missing_forwarded_for_stays_none():
    assert redact_forwarded_for(None) is None

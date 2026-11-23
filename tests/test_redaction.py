from fastapi.testclient import TestClient

import app as app_module
from logging_setup import redact_forwarded_for


class RecordingLogger:
    """Stands in for the app's logger and keeps each call's fields."""

    def __init__(self):
        self.calls = []

    def info(self, event, **fields):
        self.calls.append((event, fields))

    error = info


def test_forwarded_for_reaches_the_log_redacted(monkeypatch):
    rec = RecordingLogger()
    monkeypatch.setattr(app_module, "logger", rec)

    TestClient(app_module.app).get(
        "/livez", headers={"X-Forwarded-For": "203.0.113.7, 10.0.0.5"}
    )

    [(_, fields)] = [c for c in rec.calls if c[0] == "request_served"]
    assert fields["forwarded_for"] == "203.0.113.x, 10.0.0.x"


def test_every_hop_in_forwarded_for_is_redacted():
    assert redact_forwarded_for("203.0.113.7, 10.0.0.5") == "203.0.113.x, 10.0.0.x"


def test_missing_forwarded_for_stays_none():
    assert redact_forwarded_for(None) is None

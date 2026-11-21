import re

import psycopg


def test_request_id_echoed(client):
    r = client.get("/livez", headers={"X-Request-ID": "abc-123_XYZ"})

    assert r.headers["X-Request-ID"] == "abc-123_XYZ"


def test_request_id_rejected(client):
    long_id = "a" * 500
    r = client.get("/livez", headers={"X-Request-ID": long_id})

    rid = r.headers["X-Request-ID"]
    assert rid != long_id  # not echoed back
    assert re.fullmatch(r"[A-Za-z0-9_-]{1,64}", rid)  # replaced with a valid one


def test_db_error_does_not_leak(client, fake_db, monkeypatch):
    class BrokenPool:
        def connection(self):
            # Same exception a dead database raises, with the secrets IN the message,
            # so code that echoes the error would really leak them.
            raise psycopg.OperationalError(
                f'connection to server at "{fake_db["DB_HOST"]}", port 5432 failed: '
                f'FATAL: password authentication failed for user "{fake_db["DB_USER"]}"'
            )

    monkeypatch.setattr(client.app.state, "pool", BrokenPool(), raising=False)
    r = client.get("/scores/top")

    assert r.status_code == 503
    assert r.json() == {"detail": "Database unavailable"}
    assert fake_db["DB_HOST"] not in r.text
    assert fake_db["DB_USER"] not in r.text
    assert "X-Request-ID" in r.headers


def test_metrics_exposes_route_label(client):
    client.get("/livez", headers={"X-Request-ID": "metrics-probe-id"})
    client.get("/wp-login.php")
    body = client.get("/metrics").text

    assert 'route="/livez"' in body
    assert 'route="__unmatched__"' in body
    assert "wp-login" not in body  # raw paths never become labels
    assert "request_id" not in body  # IDs never become labels
    assert "metrics-probe-id" not in body

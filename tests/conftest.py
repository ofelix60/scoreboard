import os

import pytest
from fastapi.testclient import TestClient

# These run when pytest loads this file, which is before it imports any test.
# app.py builds AppSettings() at import time, so the variables must already exist.
# Real environment variables beat .env, so these fake values win over the real .env.
FAKE_DB = {
    "DB_HOST": "fake-db-host.internal",
    "DB_PORT": "5432",
    "DB_USER": "fake_db_user",
    "DB_PASSWORD": "fake-db-password",
    "DB_NAME": "fake_db",
}
os.environ.update(FAKE_DB)


@pytest.fixture
def fake_db():
    """The fake connection values, for tests that check they don't leak."""
    return FAKE_DB


@pytest.fixture
def client():
    """A client that calls the app in-process. No lifespan, so no database pool."""
    from app import app

    return TestClient(app)

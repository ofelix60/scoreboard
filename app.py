import re
import secrets
import socket
import time
from contextlib import asynccontextmanager
from typing import Annotated

import psycopg
import structlog
from fastapi import Depends, FastAPI, HTTPException, Query, Request, Response
from fastapi.responses import JSONResponse
from prometheus_client import (
    CONTENT_TYPE_LATEST,
    Counter,
    Gauge,
    Histogram,
    generate_latest,
)
from psycopg_pool import ConnectionPool
from pydantic import BaseModel, Field
from pydantic_settings import BaseSettings, SettingsConfigDict

from logging_setup import initialize_logging, redact_ip

logger = initialize_logging()

# Latency buckets, in seconds, chosen from measured request durations (see the 1.2 logs):
# /livez ~0.5ms, /scores/top ~1.4ms, /readyz ~7ms, a pool-timeout 503 ~2s.
BUCKETS = (
    0.0005,
    0.001,
    0.0025,
    0.005,
    0.01,
    0.025,
    0.05,
    0.1,
    0.25,
    0.5,
    1.0,
    2.5,
    5.0,
)

HTTP_REQUESTS = Counter(
    "scoreboard_http_requests_total",
    "HTTP requests served",
    ["method", "route", "status"],
)
HTTP_DURATION = Histogram(
    "scoreboard_http_request_duration_seconds",
    "Time spent handling a request",
    ["method", "route"],
    buckets=BUCKETS,
)
DB_READY = Gauge(
    "scoreboard_db_ready",
    "1 if the last /readyz reached the database, else 0. Updated only when /readyz is called.",
)


class AppSettings(BaseSettings):
    model_config = SettingsConfigDict(
        validate_assignment=True, case_sensitive=True, extra="ignore", env_file=".env"
    )
    DB_HOST: str
    DB_PORT: int
    DB_USER: str
    DB_PASSWORD: str
    DB_NAME: str


settings = AppSettings()  # type: ignore


class Score(BaseModel):
    player: str = Field(min_length=1)
    score: int = Field(ge=0)


db_url = f"postgresql://{settings.DB_USER}:{settings.DB_PASSWORD}@{settings.DB_HOST}:{settings.DB_PORT}/{settings.DB_NAME}"


@asynccontextmanager
async def lifespan(app: FastAPI):
    pool = ConnectionPool(
        conninfo=db_url,
        min_size=2,
        max_size=10,
        open=False,
        timeout=2,
        check=ConnectionPool.check_connection,
    )
    pool.open()
    app.state.pool = pool
    yield
    pool.close()


app = FastAPI(lifespan=lifespan)

REQUEST_ID_RE = re.compile(r"[A-Za-z0-9_-]{1,64}")


@app.middleware("http")
async def request_logger(request: Request, call_next):
    rid = request.headers.get("x-request-id", "")
    if not REQUEST_ID_RE.fullmatch(rid):
        rid = secrets.token_urlsafe(12)

    structlog.contextvars.clear_contextvars()
    structlog.contextvars.bind_contextvars(request_id=rid)

    request.state.log_context = {}

    exc: Exception | None = None
    start = time.perf_counter()
    try:
        response = await call_next(request)
    except Exception as e:
        exc = e
        response = JSONResponse({"detail": "internal server error"}, status_code=500)

    ctx = request.state.log_context
    # crash path OR what an endpoint/dependency handed us
    exc = exc or ctx.pop("exc", None)

    response.headers["X-Request-ID"] = rid
    route = request.scope.get("route")
    route_tmpl = getattr(route, "path", "__unmatched__")
    duration = time.perf_counter() - start

    # Metrics: a scrape counting itself would add a fake request every 15s and skew the rate.
    if route_tmpl != "/metrics":
        HTTP_REQUESTS.labels(
            request.method, route_tmpl, str(response.status_code)
        ).inc()
        HTTP_DURATION.labels(request.method, route_tmpl).observe(duration)

    log = logger.error if response.status_code >= 500 else logger.info
    log(
        "request_served",
        method=request.method,
        route=route_tmpl,
        status=response.status_code,
        duration_ms=round(duration * 1000, 2),
        client_ip=redact_ip(request.client.host)
        if request.client
        else None,  # the connection's IP (Caddy)
        forwarded_for=request.headers.get(
            "x-forwarded-for"
        ),  # what Caddy says the visitor was
        user_agent=request.headers.get("user-agent"),
        exc_info=exc,
        **ctx,
    )
    return response


def get_connection(request: Request):
    pool: ConnectionPool = request.app.state.pool
    try:
        with pool.connection() as conn:
            yield conn
    except psycopg.OperationalError as e:
        # Log side: hand the real error to the middleware's request line.
        request.state.log_context["exc"] = e
        request.state.log_context["db_host"] = settings.DB_HOST
        # Client side: generic message only.
        raise HTTPException(503, "Database unavailable") from e


Conn = Annotated[psycopg.Connection, Depends(get_connection)]


@app.get("/livez")
def livez() -> dict:
    return {
        "status": "ok",
        "hostname": socket.gethostname(),
    }


@app.get("/readyz")
def readyz() -> dict:
    try:
        with psycopg.connect(db_url, connect_timeout=1) as conn, conn.cursor() as cur:
            cur.execute("SELECT 1")
        DB_READY.set(1)
        return {
            "status": "ok",
            "database": "ok",
            "hostname": socket.gethostname(),
        }
    except psycopg.OperationalError:
        DB_READY.set(0)
        raise HTTPException(
            status_code=503,
            detail="Database unavailable",
        )


@app.post("/scores", status_code=201)
def create_score(conn: Conn, payload: Score) -> Score:
    q = "INSERT INTO scores (player, score) VALUES (%s, %s)"

    with conn.cursor() as cur:
        cur.execute(q, (payload.player, payload.score))

    return payload


@app.get("/scores/top")
def top_scores(conn: Conn, limit: int = Query(10, ge=1, le=100)) -> list[Score]:
    q = "SELECT player, score FROM scores ORDER BY score DESC LIMIT %s"

    top_n = []
    with conn.cursor() as cur:
        cur.execute(q, (limit,))
        for player, score in cur:
            top_n.append(Score(player=player, score=score))

    return top_n


@app.get("/metrics", include_in_schema=False)
def metrics() -> Response:
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)

import socket
from contextlib import asynccontextmanager
from typing import Annotated

import psycopg
from fastapi import Depends, FastAPI, HTTPException, Query, Request
from psycopg_pool import ConnectionPool
from pydantic import BaseModel, Field
from pydantic_settings import BaseSettings, SettingsConfigDict


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


def get_connection(request: Request):
    pool: ConnectionPool = request.app.state.pool
    try:
        with pool.connection() as conn:
            yield conn
    except psycopg.OperationalError as e:
        raise HTTPException(503, f"Database unavailable:\n{e}")


Conn = Annotated[psycopg.Connection, Depends(get_connection)]


@app.get("/health")
def health() -> dict:
    try:
        with psycopg.connect(db_url, connect_timeout=1) as conn, conn.cursor() as cur:
            cur.execute("SELECT 1")
        return {
            "status": "ok",
            "database": "ok",
            "hostname": socket.gethostname(),
        }
    except psycopg.OperationalError:
        raise HTTPException(
            status_code=503,
            detail="Database unavailable",
        )


@app.post("/scores", status_code=201)
def create_score(conn: Conn, payload: Score) -> Score:
    q = "INSERT INTO scores (player, score) VALUES (%s, %s)"

    with conn.cursor() as cur:
        cur.execute(q, (payload.player, payload.score))
        conn.commit()

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

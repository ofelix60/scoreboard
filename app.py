import os
from typing import Annotated

import psycopg
from dotenv import load_dotenv
from fastapi import Depends, FastAPI, Query
from pydantic import BaseModel, Field


class Score(BaseModel):
    player: str = Field(min_length=1)
    score: int = Field(ge=0)


app = FastAPI()
load_dotenv()
DB_URL: str | None = os.getenv("DB_URL")

DB_HOST = os.getenv("DB_HOST")
DB_PORT = os.getenv("DB_PORT")
DB_USER = os.getenv("DB_USER")
DB_PASSWORD = os.getenv("DB_PASSWORD")
DB_NAME = os.getenv("DB_NAME")

db_url = f"postgresql://{DB_USER}:{DB_PASSWORD}@{DB_HOST}:{DB_PORT}/{DB_NAME}"


def get_connection():
    try:
        pass
    except psycopg.OperationalError as e:
        raise ConnectionError(503, f"Database unavailable {e}")
    with psycopg.connect(db_url) as conn:
        yield conn


Conn = Annotated[psycopg.Connection, Depends(get_connection)]


@app.get("/health")
def health() -> dict:
    return {"status": "ok"}


@app.post("/scores", status_code=201)
def create_score(conn: Conn, payload: Score) -> Score:
    q = "INSERT INTO scores (player, score) VALUES (%s, %s)"

    with conn.cursor() as cur:
        cur.execute(q, (payload.player, payload.score))
        conn.commit()

    return payload


@app.get("/scores/top")
def top_scores(conn: Conn, limit: int = Query(10, ge=1, le=100)) -> list[Score]:
    q = "SELECT * FROM scores ORDER BY score DESC LIMIT %s"

    top_n = []
    with conn.cursor() as cur:
        cur.execute(q, (limit,))
        for player, score in cur:
            top_n.append(Score(player=player, score=score))

    return top_n

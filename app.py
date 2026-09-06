from fastapi import FastAPI, Query
from pydantic import BaseModel, Field


class Score(BaseModel):
    player: str = Field(min_length=1)
    score: int = Field(ge=0)


app = FastAPI()

scores = [
    Score(player="WEE", score=987),
    Score(player="WII", score=700),
    Score(player="PEE", score=457),
    Score(player="PEA", score=457),
    Score(player="CHI", score=457),
    Score(player="CHEE", score=456),
    Score(player="POS", score=321),
    Score(player="BEE", score=230),
    Score(player="SEE", score=220),
    Score(player="WII", score=120),
    Score(player="FEE", score=10),
    Score(player="REE", score=5000),
]


@app.get("/health")
def health() -> dict:
    return {"status": "ok"}


@app.post("/scores", status_code=201)
def create_score(payload: Score) -> Score:

    scores.append(payload)
    scores.sort(key=lambda e: e.score, reverse=True)

    return payload


@app.get("/scores/top")
def top_scores(limit: int = Query(10, ge=1, le=100)) -> list[Score]:
    top_n = scores[0:limit]

    return top_n

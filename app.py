from fastapi import FastAPI, Query
from pydantic import BaseModel, Field


class Score(BaseModel):
    player: str = Field(min_length=1)
    score: int = Field(ge=0)


app = FastAPI()

scores = [
    Score(player="UJM", score=987),
    Score(player="GRS", score=700),
    Score(player="BGT", score=457),
    Score(player="ZGR", score=456),
    Score(player="POS", score=321),
    Score(player="BEE", score=230),
    Score(player="SEE", score=220),
    Score(player="CHI", score=120),
    Score(player="FEE", score=10),
    Score(player="REE", score=5000),
]


@app.get("/health")
def health():
    return {"status": "ok"}


@app.post("/scores", status_code=201)
def create_score(payload: Score):

    scores.append(payload)
    scores.sort(key=lambda e: e.score, reverse=True)

    return payload


@app.get("/scores/top")
def top_scores(limit: int = Query(ge=1, le=100)) -> list[Score]:
    # def top_scores(limit: int = 10) -> list[Score]:
    top_n = scores[0 : int(limit)]

    return top_n

from fastapi import FastAPI
from pydantic import BaseModel


class Score(BaseModel):
    player: str
    score: int


app = FastAPI()

all_scores = [
    {"player": "UJM", "score": 987},
    {"player": "YHN", "score": 700},
    {"player": "IKI", "score": 457},
    {"player": "PPP", "score": 456},
    {"player": "OLO", "score": 321},
    {"player": "TGB", "score": 230},
    {"player": "RFV", "score": 220},
    {"player": "WSX", "score": 200},
    {"player": "EDC", "score": 120},
    {"player": "QAZ", "score": 10},
    {"player": "QAZ", "score": 50},
    {"player": "QAZ", "score": 5000},
]


@app.get("/health")
def health():
    return {"status": "ok"}


@app.post("/scores")
def scores(payload: Score):
    entry = {"player": payload.player, "score": payload.score}
    all_scores.append(entry)
    all_scores.sort(key=lambda e: e["score"], reverse=True)

    return entry


@app.get("/scores/top")
def top_scores():
    top_n = all_scores[0:10]

    return top_n

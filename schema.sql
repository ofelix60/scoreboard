CREATE TABLE IF NOT EXISTS scores (
    player TEXT NOT NULL,
    score INTEGER NOT NULL CHECK (score >= 0)
);

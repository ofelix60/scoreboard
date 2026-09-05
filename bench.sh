#!/usr/bin/env bash
# usage: ./bench.sh v1 "what changed"
set -euo pipefail
TAG=$1; NOTE=${2:-}
IMG="scoreboard:$TAG"

now() { python3 -c 'import time; print(time.time())'; }
since() { python3 -c "import time; print(f'{time.time()-$1:.2f}')"; }

t=$(now)
docker build --no-cache -t "$IMG" .
cold=$(since "$t")

echo "# bench $(date +%s)" >> scratch.txt

t=$(now)
docker build -t "$IMG" .
warm=$(since "$t")

mb=$(( $(docker image inspect "$IMG" --format '{{.Size}}') / 1000000 ))

echo "| $(date +%F) | $TAG | ${mb}MB | ${cold}s | ${warm}s | $NOTE |" >> benchmarks.md
tail -1 benchmarks.md

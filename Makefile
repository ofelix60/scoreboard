SCALE ?= 2

.PHONY: \
	up down \
	fmt lint

up:
	docker compose up -d --scale api=$(SCALE)

down:
	docker compose down -v

fmt: 
	uv run ruff format .

lint: 
	uv run ruff check .


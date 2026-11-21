SCALE ?= 2

.PHONY: \
	up down \
	fmt lint

up:
	docker compose up -d --build --scale api=$(SCALE)

down:
	docker compose down

destroy:
	docker compose down -v

fmt: 
	uv run ruff format .

lint: 
	uv run ruff check .

export GIT_SHA := $(shell git rev-parse --short HEAD)
export BUILD_TIME := $(shell date -u +%Y-%m-%dT%H:%M:%SZ)

.PHONY: db_up db_down db_logs \
        caddy_up caddy_down caddy_logs \
        api_build api_up api_down api_logs \
        api_fmt api_lint fmt lint dev_up


db_up:
	docker run --name db \
		--network scoreboard \
		--env-file .env \
		-v scoreboard-vol:/var/lib/postgresql/data \
		postgres:16

db_down:
	docker rm -f db

db_logs:
	docker logs -f db


caddy_up:
	docker run -d --name caddy1 \
		--network scoreboard \
		-p 8080:8000 \
		-v $(PWD)/Caddyfile:/etc/caddy/Caddyfile \
		caddy:2

caddy_down:
	docker rm -f caddy1

caddy_logs:
	docker logs -f caddy1


api_build:
	docker build -t scoreboard:latest .

api_up:
	docker run -d --name api1 \
		--network scoreboard \
		--env-file .env \
		scoreboard:latest
	docker run -d --name api2 \
		--network scoreboard \
		--env-file .env \
		scoreboard:latest

api_down:
	docker rm -f api1 api2

api_logs:
	docker logs -f --tail 20 api1 &
	docker logs -f --tail 20 api2


fmt: uv run ruff format .

lint: uv run ruff check .

dev_up: api_build api_up caddy_up

VOL=sb-vol
NET=sb-net
DB=sb-db
LB=caddy1

.PHONY: \
	vol_up vol_down \
	net_up net_down \
	db_up db_down db_stop \
	lb_up lb_down lb_stop \
	api_build api_up api_down api_stop api_iterate api_logs \
	app_up app_stop app_down app_destroy \
	fmt lint

vol_up:
	docker volume inspect $(VOL) >/dev/null 2>&1 || docker volume create $(VOL)

vol_down:
	docker volume rm $(VOL)
	
net_up:	
	docker network inspect $(NET) >/dev/null 2>&1 || docker network create $(NET)

net_down:
	docker network rm $(NET)

db_up: vol_up net_up

	docker run -d --name $(DB) \
		--network $(NET) \
		-e POSTGRES_USER=$$(grep '^DB_USER=' .env | cut -d= -f2) \
		-e POSTGRES_PASSWORD=$$(grep '^DB_PASSWORD=' .env | cut -d= -f2) \
		-e POSTGRES_DB=$$(grep '^DB_NAME=' .env | cut -d= -f2) \
		-v $(VOL):/var/lib/postgresql/data \
		postgres:16

db_down:
	docker rm -f $(DB)

db_stop:
	docker stop $(DB)

db_logs:
	docker logs -t --tail $(DB)

caddy_up:
	docker run -d --name $(LB) \
		--network $(NET) \
		-p 8080:8000 \
		-v $(CURDIR)/Caddyfile:/etc/caddy/Caddyfile \
		caddy:2


caddy_down:
	docker rm -f $(LB)

caddy_stop:
	docker stop $(LB)

caddy_logs:
	docker logs -t --tail $(LB)


api_build:
	@test -n "$(TAG)" || (echo "Usage: make api_build TAG=v2.1"; exit 1)
	docker build -t scoreboard:$(TAG) .
	docker tag scoreboard:$(TAG) scoreboard:latest

api_up:
	docker run -d --name api1 \
		--network $(NET) \
		--env-file .env \
		scoreboard:latest
	docker run -d --name api2 \
		--network $(NET) \
		--env-file .env \
		scoreboard:latest

api_down:
	docker rm -f api1 api2

api_stop:
	docker stop api1 api2

api_iterate:
	@test -n "$(TAG)" || (echo "Usage: make api_iterate TAG=v2.1"; exit 1)
	$(MAKE) api_down
	$(MAKE) api_build TAG=$(TAG)
	$(MAKE) api_up

api_logs:
	docker logs -t --tail 20 api1
	docker logs -t --tail 20 api2


fmt: 
	uv run ruff format .

lint: 
	uv run ruff check .

app_up:
	$(MAKE) db_up
	$(MAKE) api_up
	$(MAKE) caddy_up

app_stop:
	$(MAKE) caddy_stop
	$(MAKE) api_stop
	$(MAKE) db_stop

app_down:
	$(MAKE) caddy_down
	$(MAKE) api_down
	$(MAKE) db_down

app_destroy:
	$(MAKE) app_down
	$(MAKE) net_down
	$(MAKE) vol_down




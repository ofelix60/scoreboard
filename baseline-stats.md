Baseline & Memory Limits
Method

Idle: docker stats --no-stream with no traffic.

Loaded: 15k requests at 100 concurrent:
seq 1 15000 | xargs -P 100 -I{} curl -s -o /dev/null https://localhost:8080/<endpoint>

Sample docker stats --no-stream every 2s. Peak = maximum observed during the run across both API replicas.

Idle (pre-limit)

LIMIT = host RAM; containers were effectively unlimited.

NAME	CPU %	MEM	PIDS
api1	0.25%	46.1M	10
api2	0.21%	46.6M	10
sb-db	0.00%	32.1M	10
caddy1	0.06%	27.0M	13
Loaded (15k requests, 100 concurrent)
NAME	CPU %	PEAK MEM
api1	26.46%	98.2M
api2	26.60%	53.4M
caddy1	48.59%	<fill>
sb-db	<fill>	<fill>
Limits

api1 / api2 — 256M

~2.6× the observed API peak. The headroom is deliberate: RSS is a high-water mark, not current allocation. Python/glibc may retain freed pages, so observed RSS is an imperfect proxy for actual memory demand.

The replicas peaked differently (98M vs 53M) despite identical network I/O, so both get the higher limit.

sb-db — 1G

Not derived from observed usage. PostgreSQL can consume additional memory through shared_buffers, per-connection work_mem, page cache, and unexpectedly expensive query plans.

The limit is for blast-radius containment, not efficiency: without it, a runaway query can trigger the host OOM killer and potentially kill an API instead. With it, Postgres is the component that gets killed.

caddy1 — 256M

Only 27M idle. The limit is intentionally generous; there is little benefit to tuning it tighter.

No CPU Limits

Deliberate.

The APIs use ~26% CPU under full load, while Caddy reaches ~49%. A CPU cap would not currently bind, and throttling Caddy—the entrypoint and TLS termination point—would only add latency.

Revisit CPU limits if a container demonstrably starves another.

Before Raising a Limit

An OOM kill means measure first, don't simply double the limit.

Confirm the cause:
docker inspect --format '{{.State.OOMKilled}}' <name>

Re-run the load test and record the new peak.
If the peak genuinely increased, investigate what changed in the application before raising the limit.

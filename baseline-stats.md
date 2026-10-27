# Baseline measurements and memory limits

How the `mem_limit` values in `docker-compose.yaml` were chosen.

## Method

**Idle** — `docker stats --no-stream` with no traffic.

**Loaded** — 15,000 requests at 100 concurrent:

```bash
seq 1 15000 | xargs -P 100 -I{} curl -s -o /dev/null https://localhost:8080/<endpoint>
```

Sampled `docker stats --no-stream` every 2s. Peak = maximum observed during the run,
across both API replicas.

## Idle, before limits were set

`LIMIT` was host RAM, so containers were effectively unlimited.

| container | CPU % | MEM | PIDs |
|---|---|---|---|
| api1 | 0.25% | 46.1M | 10 |
| api2 | 0.21% | 46.6M | 10 |
| sb-db | 0.00% | 32.1M | 10 |
| caddy1 | 0.06% | 27.0M | 13 |

## Under load — 15k requests, 100 concurrent

| container | CPU % | peak MEM |
|---|---|---|
| api1 | 26.46% | 98.2M |
| api2 | 26.60% | 53.4M |
| caddy1 | 48.59% | — |

## The limits, and why

**api1 / api2 — 256M.** The only limit derived from data: roughly 2.6× the observed
98.2M peak. The headroom is deliberate. RSS is a high-water mark, not current
allocation — Python and glibc may retain freed pages, so observed RSS is an imperfect
proxy for actual memory demand.

The two replicas peaked very differently (98.2M vs 53.4M) despite identical network
I/O, so both get the higher figure.

**sb-db — 1G.** *Not* derived from observed usage. PostgreSQL can consume memory
through `shared_buffers`, per-connection `work_mem`, page cache, and unexpectedly
expensive query plans — none of which a 15k-request benchmark against two endpoints
will provoke.

The limit exists for **blast-radius containment, not efficiency**: without it, a runaway
query can trigger the host OOM killer, which may then kill an API container instead.
With it, Postgres is the process that dies. That is a deliberate choice about *which*
component fails, not an attempt to right-size anything.

**caddy1 — 256M.** 27M idle. The limit is intentionally generous; there is little to
gain from tuning the TLS terminator tighter.

## No CPU limits — deliberate

The APIs sit at ~26% CPU under full load; Caddy reaches ~49%. A CPU cap would not
currently bind on anything. Throttling Caddy — the entrypoint and TLS termination
point — would add latency for no benefit.

Revisit if a container demonstrably starves another.

## Before raising any limit

An OOM kill means **measure first**, not double the number.

```bash
docker inspect --format '{{.State.OOMKilled}}' <name>
```

1. Confirm it was actually an OOM kill and not exit 137 from something else.
2. Re-run the load test and record the new peak.
3. If the peak genuinely moved, find out what changed in the application **before**
   raising the ceiling. A limit that keeps growing is a memory leak with extra steps.

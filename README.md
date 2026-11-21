# scoreboard

A small FastAPI + Postgres service, deliberately deployed four different ways:
`docker run` → Compose → Kubernetes → (next) AWS ECS.

The service itself is intentionally boring. The point of this repo is **what changes and
what doesn't when the platform changes** — service discovery, health checking,
configuration, secrets, and persistence have to be solved on every platform, and each
one solves them differently.

## The thing I actually learned

Every platform has an answer to the same eight problems. Learning the fourth platform is
mostly learning new names for things you already understand:

| Problem | Docker / Compose | Kubernetes | ECS (next) |
|---|---|---|---|
| health checking | `HEALTHCHECK`, Caddy `health_uri` | `livenessProbe` / `readinessProbe` | container health check |
| load balancing | Caddy `round_robin` over 2 replicas | Service + Deployment replicas | ALB target group |
| removing sick instances | Caddy passive health | endpoint drops out of the EndpointSlice | target deregistration |
| service discovery | bridge network, DNS by container name | cluster DNS + Service names | Cloud Map |
| configuration | `.env` + `--env-file` | ConfigMap | task def environment |
| secrets | `.env`, gitignored | Secret | task def secrets / Secrets Manager |
| persistence | named volume | PersistentVolumeClaim | EFS volume |
| resource limits | `--memory` | `resources.requests/limits` | task/container memory |

Two findings worth more than the table:

**Kubernetes ignores `HEALTHCHECK` entirely.** A Dockerfile healthcheck is invisible to
the kubelet. The same logic has to be re-declared as probes.

**Liveness and readiness are not interchangeable, and conflating them causes outages.**
`/readyz` checks the database; `/livez` does not. Pointing a *liveness* probe at a
dependency check means a database blip restarts every replica simultaneously — turning
a degraded service into no service at all. I tested this on purpose and watched the
CrashLoopBackOff.

## Architecture (Kubernetes)

```
Mac :80 ──► kind extraPortMappings ──► kind-control-plane
              └─► ingress-nginx (pinned to the control-plane node)
                    │  Host: scoreboard.127.0.0.1.nip.io
                    └─► Service scoreboard :80 → :8000
                          └─► Deployment scoreboard (2 replicas)
                              │   probes · resources · ConfigMap + Secret via envFrom
                              │   image pulled by digest from private GHCR
                              └─► StatefulSet sb-db-0 + headless Service + PVC
```

Under Compose the same service runs behind Caddy with health-gated `depends_on`. Both
stacks are in the repo and both work.

## Run it

**Compose:**
```bash
cp .env.example .env     # DB_HOST, DB_PORT, DB_USER, DB_PASSWORD, DB_NAME
make up
curl -k https://localhost:8080/readyz
```

**Kubernetes (kind):**
```bash
kind create cluster --config k8s/kind-cluster.yaml
kubectl apply -f k8s/ingress-nginx.yaml
kubectl wait -n ingress-nginx --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller --timeout=120s

# secrets are not in git — see Known gaps
kubectl apply -f k8s/secret.yaml
kubectl create secret docker-registry regcred \
  --docker-server=ghcr.io --docker-username=<user> --docker-password=<token>

kubectl apply -f k8s/configmap.yaml -f k8s/db-initdb-configmap.yaml \
  -f k8s/db-service.yaml -f k8s/db-statefulset.yaml \
  -f k8s/service.yaml -f k8s/deployment.yaml -f k8s/ingress.yaml

curl http://scoreboard.127.0.0.1.nip.io/scores/top
```

Measured: **2 minutes 5 seconds from an empty cluster to a serving stack**, using only
files in this repo plus the two secrets noted below.

## API

| Endpoint | Returns | Notes |
|---|---|---|
| `GET /livez` | 200 while the process is alive | no dependencies — deliberately dumb |
| `GET /readyz` | 200 / 503 | opens its own connection, `connect_timeout=1` |
| `POST /scores` | 201 | `{"player": str, "score": int}` |
| `GET /scores/top` | 200 | `?limit=` validated `1..100` |
| `GET /metrics` | 200 | Prometheus text format; excluded from its own counters |

Every response carries an `X-Request-ID` header, 5xx included. Quote it to find the
matching log line.

Validation is declared, not hand-written: `pydantic.Field(min_length=1)` / `Field(ge=0)`
and `Query(10, ge=1, le=100)`. Invalid input returns a 422 naming the offending field,
with no `if` statements in the handler.

## Design decisions and tradeoffs

**The connection pool lives in `lifespan`, not in the request path.** A pool created
per-request leaks threads and eventually raises `RuntimeError: cannot join current
thread`. It's an app-scoped resource, so it's opened once at startup and handed to
handlers through a dependency.

**The container healthcheck probes its own hostname, not `localhost`.** A healthcheck
curling `localhost` cannot detect the most likely bind-address fault — a process
listening on `127.0.0.1` instead of `0.0.0.0` answers itself happily while being
unreachable from outside. Verified empirically; it's why the `HEALTHCHECK` uses
`socket.gethostname()`.

**Multi-stage build, digest-pinned base, non-root.**
`ARG PY=python:3.12.14-slim-trixie@sha256:…` shared by both stages, dependencies
resolved in the builder with a cache mount, only the virtualenv copied forward.
338MB → **66.6MB**. Runs as `USER 10001`.

**Memory limits are measured, not guessed — where that's possible.** The API limit is
~2.6× the observed peak under 15k requests at 100 concurrent; the Postgres limit is
deliberately *not* usage-derived, because it exists to decide which process the OOM
killer takes rather than to right-size anything. Numbers and reasoning in
**[baseline-stats.md](baseline-stats.md)**.

**Caddy's `dynamic a` upstream discovery was a knowing tradeoff.** It enabled
`compose up --scale`, but it silently disabled active health checks, the admin API
upstream list, and the `caddy_reverse_proxy_upstreams_healthy` metric — verified by
observing zero active-checker log lines and `[]` from the admin API. Health became
passive only. Kubernetes separates these concerns properly: Services do discovery,
readiness probes do health, independently. That tradeoff is the clearest argument for
the migration in this repo.

**Logs are JSON on stdout, one line per request.** structlog writes JSON when stdout
isn't a terminal and a readable console format when it is. Containers log to stdout
because that's what `docker logs`, and later CloudWatch, reads. A log file inside a
container is a file nobody reads.

**Context is added by a processor, not a bound logger.** `service`, `env`, `hostname`,
`git_sha` and `build_time` are added by a processor in structlog's `pre_chain`. A bound
logger only reaches records that go through it. The processor also reaches uvicorn's
and psycopg's own records, and those are the ones you need during a bad deploy.

**The middleware owns the request line, not uvicorn.** uvicorn's access log is off
(`--no-access-log`), because two loggers writing one request line would count every
request twice. uvicorn's own logging setup is replaced by a no-op `logging.json`.
Without that, uvicorn attaches its own handlers and its records never reach ours.
`--log-config /dev/null` doesn't work for this: uvicorn treats any path that isn't
JSON or YAML as an INI file, and Python 3.12 rejects an empty one.

**Every log line carries the image's git SHA.** `GIT_SHA` and `BUILD_TIME` are passed
as build args and become `ENV` in the runtime stage, after every `COPY`. `BUILD_TIME`
changes on every build, and a changed `ARG` or `ENV` invalidates every layer after it.
Any earlier in the stage, every build would re-copy the venv and the source.

**Request IDs are validated, not trusted.** An inbound `X-Request-ID` is kept only if
it matches `[A-Za-z0-9_-]{1,64}`. Otherwise a new one is generated. Accepting it
unchecked would put a client-controlled string of any length on every log line. The
ID is bound with contextvars, so every log line in the request carries it.

**Sync endpoints pass log context up through `request.state`.** The endpoints are plain
`def`, so FastAPI runs them in a threadpool. contextvars are copied *into* the worker
thread but not back out. Anything an endpoint or dependency wants on the request line
goes in `request.state.log_context`, a dict the middleware reads after the endpoint
returns.

**Database errors go to the log, not the client.** A 503 body says `Database
unavailable` and nothing else. The exception, its traceback and `db_host` go on the
request line, under the same `request_id` as the response header. Before this fix, the
raw psycopg error text went into the response body. Through the pool that's the
`PoolTimeout` message. On other failure paths psycopg names the host, port and user.

**Logged tracebacks never include local variables.** Tracebacks are rendered with
`show_locals=False`. structlog's `dict_tracebacks` shorthand defaults to `True`, which
put the full DSN, password included, into the log from a stack frame's locals. The
`redact` processor can't catch that, for two reasons. It runs in `pre_chain`, *before*
the traceback is rendered. And it only checks top-level keys, while locals are nested
inside the traceback.

**`scoreboard_db_ready` is set by `/readyz`, not by the scrape.** This coupling is
deliberate. Querying the database on every `GET /metrics` would make the metrics endpoint
a free way to send load to the database. Instead, whatever already probes readiness on a
timer keeps the gauge fresh: the compose `HEALTHCHECK` every 10s, the k8s
`readinessProbe`, and later the ALB health check. Removing those probes silently freezes
the gauge. See Known gaps.

**Metric labels are bounded by design.** Requests are labelled by the matched route
template, with unmatched paths collapsed into `__unmatched__`, never by the raw path or
the request ID. A scanner trying ten thousand URLs produces one series, not ten thousand.
Histogram buckets come from measured latencies (`/livez` ~0.5ms, `/scores/top` ~1.4ms,
`/readyz` ~7ms, a pool-timeout 503 ~2s), not the library defaults, which start at 5ms
and would put almost every request in the first bucket.

**The ingress-nginx manifest is vendored, not applied from a URL.** Pinned to
`controller-v1.15.1`. Vendoring means the version can't drift and — more importantly —
the manifest can be patched: the upstream kind provider dropped the `ingress-ready`
nodeSelector, so without re-adding it the controller schedules onto a node with no host
port mapping and every request hangs with no error logged anywhere. You cannot patch a
URL.

## Known gaps

Known, not hidden. Each has a decided fix.

- **Schema is owned by `initdb`, which only runs against an empty data directory.**
  Editing `k8s/db-initdb-configmap.yaml` will silently never apply to an existing
  database. This seeds; it does not migrate. Needs a migration tool (Alembic, dbmate) as
  an initContainer or Job.
- **Restore is not properly validated.** A `pg_dump` → restore cycle emitted
  `ERROR: relation "scores" already exists` and still appeared to succeed, because the
  existing table happened to match. Needs `--clean --if-exists` and a test against a
  non-trivial dataset.
- **Two things aren't reproducible from git:** the app Secret (a template is committed,
  the real values are not) and the GHCR `imagePullSecret`, created by hand. Both should
  come from CI or an external secret store.
- **Nine raw manifests, no templating.** Fine for one environment, wrong for two.
  Helm or Kustomize.
- **No CI.** The image is built and pushed by hand.
- **A single-replica database as a `Deployment` would deadlock** — RWO volume,
  `maxUnavailable` rounds down to 0, the new pod waits for a volume the old pod won't
  release. It's a StatefulSet, which sidesteps that, but the honest answer for a
  single-instance database is `strategy: Recreate` and accepting the downtime.
- **`scoreboard_db_ready` goes stale if nothing probes `/readyz`.** It keeps showing
  the last value it was set to, so it can be out of date but never invented. It reads 0
  from process start until the first probe. Each replica updates its own gauge on its
  own healthcheck schedule, so two replicas can briefly disagree.
- **Metrics assume one worker per container.** Each uvicorn process keeps its own
  counters in memory. Replicas are fine: each container is a separate scrape target and
  Prometheus adds them up. Running `--workers N` inside one container is not fine: the
  workers share one port, so each scrape would show a random worker's numbers. That
  would need `PROMETHEUS_MULTIPROC_DIR` and a `MultiProcessCollector`.
- **`forwarded_for` is logged exactly as received.** `X-Forwarded-For` can be set by
  the client, so it isn't trusted as identity. Unlike `client_ip`, it isn't
  IP-redacted either.
- **`/readyz` discards the reason for a failure.** Its 503 detail is correctly
  generic, but the exception isn't logged, so a failing readiness check leaves no
  record of why. Only the `scoreboard_db_ready` gauge changes.
- **In production this would be a managed database** (RDS/Cloud SQL), not a hand-rolled
  StatefulSet. Running Postgres in-cluster costs staff time; if it had to be in-cluster
  it should use an operator, not this.

## Layout

```
app.py                    FastAPI app, pool lifecycle, endpoints, middleware, metrics
logging_setup.py          structlog config: JSON on stdout, static context, redaction
logging.json              no-op uvicorn log config, so its records reach ours
build.py                  reads GIT_SHA / BUILD_TIME from the environment
sensitive_keys.py         key names the redact processor masks
schema.sql                table definition
Dockerfile                multi-stage, digest-pinned, non-root
docker-compose.yaml       db + api + caddy, health-gated depends_on
Caddyfile                 reverse proxy, dynamic upstream discovery
Makefile                  up / down / destroy / fmt / lint
bench.sh                  build time + image size, appended to benchmarks.md
baseline-stats.md         measured usage, and why each mem_limit is what it is
.env.example              the five variables Compose needs
.dockerignore             keeps .env, k8s/ (incl. the real Secret), terraform/ and caches out of the image
terraform/envs/dev/
  backend.tf              S3 remote state, native lockfile, default_tags
k8s/
  kind-cluster.yaml       3-node cluster, extraPortMappings, ingress-ready label
  ingress-nginx.yaml      vendored controller-v1.15.1, nodeSelector patched
  deployment.yaml         2 replicas, probes, resources, envFrom, imagePullSecrets
  service.yaml            ClusterIP :80 → :8000
  ingress.yaml            host-based routing
  configmap.yaml          non-secret config
  secret.example.yaml     shape of the Secret; the real one is gitignored
  serviceaccount.yaml     zero-permission SA, token mount disabled
  teammate-role.yaml      least-privilege Role + RoleBinding (pods/logs, no secrets)
  db-statefulset.yaml     Postgres + volumeClaimTemplates
  db-service.yaml         headless
  db-initdb-configmap.yaml
```

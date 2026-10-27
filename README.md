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

**Caddy's `dynamic a` upstream discovery was a knowing tradeoff.** It enabled
`compose up --scale`, but it silently disabled active health checks, the admin API
upstream list, and the `caddy_reverse_proxy_upstreams_healthy` metric — verified by
observing zero active-checker log lines and `[]` from the admin API. Health became
passive only. Kubernetes separates these concerns properly: Services do discovery,
readiness probes do health, independently. That tradeoff is the clearest argument for
the migration in this repo.

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
- **In production this would be a managed database** (RDS/Cloud SQL), not a hand-rolled
  StatefulSet. Running Postgres in-cluster costs staff time; if it had to be in-cluster
  it should use an operator, not this.

## Layout

```
app.py                  FastAPI app, pool lifecycle, endpoints
schema.sql              table definition
Dockerfile              multi-stage, digest-pinned, non-root
docker-compose.yaml     db + api + caddy, health-gated depends_on
Caddyfile               reverse proxy, dynamic upstream discovery
Makefile                up / down / destroy / fmt / lint
k8s/
  kind-cluster.yaml     3-node cluster, extraPortMappings, ingress-ready label
  ingress-nginx.yaml    vendored controller-v1.15.1, nodeSelector patched
  deployment.yaml       2 replicas, probes, resources, envFrom, imagePullSecrets
  service.yaml          ClusterIP :80 → :8000
  ingress.yaml          host-based routing
  configmap.yaml        non-secret config
  db-statefulset.yaml   Postgres + volumeClaimTemplates
  db-service.yaml       headless
  db-initdb-configmap.yaml
```

# Known gaps

Known, not hidden. Each has a decided fix.

## AWS

- **The app reads the database password once, at boot, but RDS rotates it every 7
  days.** Open connections survive a rotation. A new connection after that, from a pool
  refill or a database restart, would fail until the instance is replaced. Fix: on
  an authentication failure, read the secret again and retry, or switch to RDS IAM
  authentication.
- **No TLS at the front door, and the database certificate isn't verified.** The ALB
  listens on HTTP :80 only, because there's no domain or certificate. The app connects
  to RDS with libpq's default `sslmode=prefer`, so the connection is encrypted but the
  server's certificate isn't checked. AWS's own connection example uses
  `sslmode=verify-full` with the RDS CA bundle.
- **Instances are in public subnets, with no NAT gateway.** A NAT gateway is about $33
  a month before data charges, more than any other single resource here. Inbound traffic is only allowed from the
  ALB's security group, but outbound is open, and the instance reaches ECR, Secrets
  Manager and CloudWatch over the internet. Fix: private subnets with VPC endpoints.
- **`/metrics` is reachable through the ALB, with no authentication.** The listener
  forwards every path. It should be blocked at the listener and scraped from inside
  the VPC.
- **One of everything.** One instance (two only during a deploy) and a single-AZ
  database. The drill's 10-minute outage is what that costs. Multi-AZ RDS would turn
  most of those into a failover of a minute or two, for twice the database cost.
- **A bad deploy is stopped, not rolled back.** The lifecycle hook keeps a broken
  instance from serving, but the refresh then just waits until someone cancels it.
  `auto_rollback` on the instance refresh would revert it automatically.
- **Deploys are a manual step.** CI publishes every `main` image to ECR, but
  `terraform apply` runs from a laptop. Running it in CI needs a role that can change
  infrastructure, which is a much bigger permission than pushing an image. The
  Kubernetes stack still pulls from GHCR, which is pushed by hand.
- **The schema on RDS was applied by hand**, over an SSM session. It's the same
  missing migration tool as the `initdb` gap below, now on all three platforms.
- **SSM sessions are recorded, but not what's typed in them.** CloudTrail logs who
  opened a session on which instance, and when. Recording the commands themselves needs
  Session Manager's logging to S3 or CloudWatch.

## The app

- **The app can't be imported without database settings.** `settings = AppSettings()`
  and `db_url` run when `app.py` is imported, so the tests set fake `DB_*` variables
  before importing it (see `tests/conftest.py`). Building settings inside `lifespan` or
  a function would remove that coupling. There are no integration tests against a real
  Postgres yet. The four tests cover request ID handling, the 503 body and metric labels
  without a database.
- **`/readyz` discards the reason for a failure.** Its 503 detail is correctly
  generic, but the exception isn't logged, so a failing readiness check leaves no
  record of why. Only the `scoreboard_db_ready` gauge changes.
- **`forwarded_for` is client-controlled.** Each address in `X-Forwarded-For` is
  IP-redacted like `client_ip`, but a client can put anything in the header. Behind
  the ALB, only the last address is one the load balancer added itself, so it's the only
  one to trust.
- **`HEAD /livez` returns 405.** FastAPI's `@app.get` doesn't answer HEAD, and many
  uptime checkers use it. One more decorator fixes it.

## Observability

- **A firing alert notifies nobody.** Locally there's no Alertmanager, so the alert
  only shows up at http://localhost:9090/alerts. On AWS, the CloudWatch alarm has no
  SNS action. In the outage drill I only knew it had fired because I was polling it.
- **The AWS alarm watches host health, not what users see.** It needs five 1-minute
  datapoints, and CloudWatch publishes them about 2 minutes late, so detection took
  7m38s of a 10-minute outage. An alarm on the ratio of `HTTPCode_Target_5XX_Count` to
  `RequestCount` would fire sooner, at the cost of more false alarms.
- **The alert misses short outages and outages on a quiet service.** A measured 1m55s
  database outage peaked at a 2.5% error ratio and never fired. Below 0.1 req/s, the
  traffic condition blocks the alert even if every request fails. Docker's `/readyz`
  healthchecks (0.2 req/s) count as traffic, so during a database outage they're what
  keeps the alert able to fire. They're also most of the "failing requests". A separate
  `scoreboard_db_ready == 0` alert would cover "broken while quiet".
- **`scoreboard_db_ready` goes stale if nothing probes `/readyz`.** It keeps showing
  the last value it was set to, so it can be out of date but never invented. It reads 0
  from process start until the first probe. Each replica updates its own gauge on its
  own healthcheck schedule, so two replicas can briefly disagree.
- **Metrics assume one worker per container.** Each uvicorn process keeps its own
  counters in memory. Replicas are fine: each container is a separate scrape target and
  Prometheus adds them up. Running `--workers N` inside one container is not fine: the
  workers share one port, so each scrape would show a random worker's numbers. That
  would need `PROMETHEUS_MULTIPROC_DIR` and a `MultiProcessCollector`.
- **p95 latency is an estimate, and it can be well off.** `histogram_quantile` only
  knows which bucket a request fell in, and it assumes requests are spread evenly
  inside that bucket. Measured: `/livez` p95 read **2.2ms** on the dashboard, but the
  exact `duration_ms` values from the logs for the same 5 minutes gave **1.3ms**. Most
  requests were just over 1ms, inside a 1ms–2.5ms bucket. Pool-timeout requests at
  about 2.0s showed as about 2.4s for the same reason. The fix is an extra bucket at
  `0.0015`. Every bucket adds a series for each method, route and instance, so it
  hasn't been added yet.
- **The app only measures requests that reach it.** During the outage in the [dashboard screenshot](grafana-red-db-outage.png),
  Caddy's passive health check (`unhealthy_status 5xx`) marked *both* replicas down and
  answered requests itself, including `/livez`, which doesn't use the database. Those
  requests never reached the middleware. Healthy requests disappeared from the count
  along with failing ones, so the error ratio peaked at about 97%, higher than what
  clients actually saw. It also slows the alert down. During an outage only about 0.3
  req/s of errors reach the app, instead of the ~8 req/s the clients are sending, so
  the 5-minute ratio takes about 3 minutes to pass 5% instead of about 15 seconds. Fix:
  scrape Caddy's own metrics as well, and on AWS use the load balancer's request
  metrics.

## Kubernetes and Compose

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
- **A single-replica database as a `Deployment` would deadlock** — RWO volume,
  `maxUnavailable` rounds down to 0, the new pod waits for a volume the old pod won't
  release. It's a StatefulSet, which sidesteps that, but the honest answer for a
  single-instance database is `strategy: Recreate` and accepting the downtime.
- **The Kubernetes stack runs its own Postgres.** The AWS stack uses RDS, which is the
  right answer in production. Running Postgres in-cluster costs staff time; if it had to
  be in-cluster it should use an operator, not a hand-rolled StatefulSet.

## Build and supply chain

- **The base image has known vulnerabilities.** ECR's scan on push reports 6 critical
  and 28 high findings, all in Debian packages in the pinned
  `python:3.12.14-slim-trixie` base, none in the app's dependencies. Fix: update the pinned digest regularly
  (Dependabot can do it) and re-scan.
- **Every `make up` restarts the api containers**, even when every build step is
  `CACHED`. `BUILD_TIME` is new on every run, so the image's `ENV` changes and so does its
  ID. Using the last commit's timestamp would make the image change only when the code
  does.

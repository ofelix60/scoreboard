# Design decisions and tradeoffs

Why the code and config are the way they are. Each decision is one I'd defend out loud;
where a number is quoted, it was measured.

## The app

### The connection pool lives in `lifespan`, not in the request path

A pool created per-request leaks threads and eventually raises `RuntimeError: cannot
join current thread`. It's an app-scoped resource, so it's opened once at startup and
handed to handlers through a dependency.

### Database errors go to the log, not the client

A 503 body says `Database unavailable` and nothing else. The exception, its traceback
and `db_host` go on the request line, under the same `request_id` as the response
header. Before this fix, the raw psycopg error text went into the response body. Through
the pool that's the `PoolTimeout` message. On other failure paths psycopg names the
host, port and user.

## The image

### Multi-stage build, digest-pinned base, non-root

`ARG PY=python:3.12.14-slim-trixie@sha256:…` shared by both stages, dependencies
resolved in the builder with a cache mount, only the virtualenv copied forward. 338MB →
**66.6MB**. Runs as `USER 10001`.

### The container healthcheck probes its own hostname, not `localhost`

A healthcheck curling `localhost` cannot detect the most likely bind-address fault — a
process listening on `127.0.0.1` instead of `0.0.0.0` answers itself happily while being
unreachable from outside. Verified empirically; it's why the `HEALTHCHECK` uses
`socket.gethostname()`.

### Memory limits are measured, not guessed — where that's possible

The API limit is ~2.6× the observed peak under 15k requests at 100 concurrent; the
Postgres limit is deliberately *not* usage-derived, because it exists to decide which
process the OOM killer takes rather than to right-size anything. Numbers and reasoning
in **[baseline-stats.md](../baseline-stats.md)**.

## Logging

### Logs are JSON on stdout, one line per request

structlog writes JSON when stdout isn't a terminal and a readable console format when it
is. Containers log to stdout because that's what `docker logs`, and later CloudWatch,
reads. A log file inside a container is a file nobody reads.

### Context is added by a processor, not a bound logger

`service`, `env`, `hostname`, `git_sha` and `build_time` are added by a processor in
structlog's `pre_chain`. A bound logger only reaches records that go through it. The
processor also reaches uvicorn's and psycopg's own records, and those are the ones you
need during a bad deploy.

### The middleware owns the request line, not uvicorn

uvicorn's access log is off (`--no-access-log`), because two loggers writing one request
line would count every request twice. uvicorn's own logging setup is replaced by a no-op
`logging.json`. Without that, uvicorn attaches its own handlers and its records never
reach ours. `--log-config /dev/null` doesn't work for this: uvicorn treats any path that
isn't JSON or YAML as an INI file, and Python 3.12 rejects an empty one.

### Every log line carries the image's git SHA

`GIT_SHA` and `BUILD_TIME` are passed as build args and become `ENV` in the runtime
stage, after every `COPY`. `BUILD_TIME` changes on every build, and a changed `ARG` or
`ENV` invalidates every layer after it. Any earlier in the stage, every build would
re-copy the venv and the source.

### Request IDs are validated, not trusted

An inbound `X-Request-ID` is kept only if it matches `[A-Za-z0-9_-]{1,64}`. Otherwise a
new one is generated. Accepting it unchecked would put a client-controlled string of any
length on every log line. The ID is bound with contextvars, so every log line in the
request carries it.

### Sync endpoints pass log context up through `request.state`

The endpoints are plain `def`, so FastAPI runs them in a threadpool. contextvars are
copied *into* the worker thread but not back out. Anything an endpoint or dependency
wants on the request line goes in `request.state.log_context`, a dict the middleware
reads after the endpoint returns.

### Logged tracebacks never include local variables

Tracebacks are rendered with `show_locals=False`. structlog's `dict_tracebacks`
shorthand defaults to `True`, which put the full DSN, password included, into the log
from a stack frame's locals. The `redact` processor can't catch that, for two reasons.
It runs in `pre_chain`, *before* the traceback is rendered. And it only checks top-level
keys, while locals are nested inside the traceback.

## Metrics, dashboard and alerting

### `scoreboard_db_ready` is set by `/readyz`, not by the scrape

This coupling is deliberate. Querying the database on every `GET /metrics` would make
the metrics endpoint a free way to send load to the database. Instead, whatever already
probes readiness on a timer keeps the gauge fresh: the compose `HEALTHCHECK` every 10s,
the k8s `readinessProbe`, and later the ALB health check. Removing those probes silently
freezes the gauge. See [known gaps](known-gaps.md#observability).

### Metric labels are bounded by design

Requests are labelled by the matched route template, with unmatched paths collapsed into
`__unmatched__`, never by the raw path or the request ID. A scanner trying ten thousand
URLs produces one series, not ten thousand. Histogram buckets come from measured
latencies (`/livez` ~0.5ms, `/scores/top` ~1.4ms, `/readyz` ~7ms, a pool-timeout 503
~2s), not the library defaults, which start at 5ms and would put almost every request in
the first bucket.

### Prometheus finds the replicas through DNS, not a fixed address

`make up` runs two api containers behind one name. A static `api:8000` target goes
through Docker's round-robin DNS, so each scrape hits a different replica. Both counters
end up in one series, and every switch looks like a counter reset to `rate()`.
`dns_sd_configs` looks up all of `api`'s A records instead and scrapes each container as
its own target, with its own `instance` label. Caddy's `dynamic a` block uses the same
mechanism to route traffic. When containers are replaced, both pick up the new addresses
within 5s.

### The dashboard is a file in the repo, not something clicked together in the UI

Grafana loads the datasource and `scoreboard.json` from `grafana/provisioning/` on
startup. A dashboard saved in the UI lives in the container's internal database and is
gone when the container is removed. To change it, edit it in the UI, copy the JSON, and
replace the file. Grafana won't save over a provisioned dashboard. The datasource has a
fixed `uid: prometheus`, because the exported JSON refers to the datasource by uid.
Without it, Grafana makes up a new random uid on every fresh start, and every panel
reports "datasource not found".

### The error panel reads 0%, not "No data", when nothing is failing

No 5xx series exists until the first 5xx happens, and dividing an empty result gives an
empty result. `or vector(0)` substitutes 0 for the missing top half of the ratio.

### Successful scrapes aren't logged

Two replicas scraped every 5s produced 24 request lines a minute that buried real
traffic. Most scrape failures (container down, network) never reach the app, so the app
couldn't log them anyway. Prometheus records them itself, in `up` and
`scrape_duration_seconds`. A `/metrics` response of 500 or above is still logged.

### The error-rate alert needs both a ratio and enough traffic

`ScoreboardHighErrorRate` fires when more than 5% of requests are 5xx for 5 minutes,
*and* traffic is above 0.1 req/s. Without the traffic condition, one failed request on
an idle service is a 100% error rate. The rule has `promtool` unit tests, and each test
was checked by breaking the rule on purpose. Deleting the traffic condition fails the
"stays quiet on a low-traffic service" test. Setting `for: 0m` fails the "fires after 5
minutes" test at minute 3. The test the plan originally suggested for the traffic
condition (a single failed request) passed even with the condition deleted: `for: 5m`
alone kept it quiet. Measured against a real database outage, the alert went pending
after 2m52s and fired after **7m52s**. What to do when it fires is in
**[runbook.md](runbook.md)**.

### Prometheus and Grafana listen on 127.0.0.1 only, and Grafana allows anonymous viewing

Prometheus has no authentication at all. Anonymous Viewer is a deliberate choice, so the
dashboard opens without a login for a demo or a screenshot. Both choices are only safe
because the ports aren't reachable from the network. Editing needs the admin login
(`GRAFANA_PASSWORD`, default `admin`).

## Platforms

### Caddy's `dynamic a` upstream discovery was a knowing tradeoff

It enabled `compose up --scale`, but it silently disabled active health checks, the
admin API upstream list, and the `caddy_reverse_proxy_upstreams_healthy` metric —
verified by observing zero active-checker log lines and `[]` from the admin API. Health
became passive only. Kubernetes separates these concerns properly: Services do
discovery, readiness probes do health, independently. That tradeoff is the clearest
argument for the migration in this repo.

### The ingress-nginx manifest is vendored, not applied from a URL

Pinned to `controller-v1.15.1`. Vendoring means the version can't drift and — more
importantly — the manifest can be patched: the upstream kind provider dropped the
`ingress-ready` nodeSelector, so without re-adding it the controller schedules onto a
node with no host port mapping and every request hangs with no error logged anywhere.
You cannot patch a URL.

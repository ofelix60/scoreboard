# Runbook

One entry per alert. Each alert's `runbook_url` annotation links to its entry here.

## ScoreboardHighErrorRate

**5xx ratio above 5% for 5 minutes, with more than 0.1 req/s of traffic.**
Rule: [`prometheus/alerts.yml`](../prometheus/alerts.yml).

**What it means:** more than one in twenty requests reaching the app returned a 5xx,
continuously for five minutes, with enough traffic for the ratio to mean something. The
usual cause is the database: `/scores`, `/scores/top` and `/readyz` return 503 when they
can't get a connection. `/livez` has no dependencies and stays green, so liveness alone
tells you nothing here.

By the time this fires, the problem has been going on for a while. In a measured
database outage it fired **7m52s** after the database stopped: 2m52s for the ratio to
climb past 5%, then the 5-minute `for`. Look at what happened about eight minutes before
the alert, not at what happened just before it.

**First checks:**

1. **Is the database reachable?** In Prometheus (http://localhost:9090/query):
   ```promql
   scoreboard_db_ready
   ```
   One row per replica. `0` means that replica's last readiness check couldn't reach
   the database, so start at the database, not the app.
2. **Which routes are failing?**
   ```promql
   sum by (route, status) (rate(scoreboard_http_requests_total[1m]))
   ```
   `/scores/top` and `/readyz` returning 503 while `/livez` returns 200 means the
   database. A single route failing on its own means a code path.
3. **Read one failing request in full.** Every 5xx is logged at `error` level. Skip
   `/readyz`: its 503 lines don't include the reason (see Known gaps in the README). A
   `/scores/top` 503 carries the exception (usually `PoolTimeout: couldn't get a
   connection after 2.00 sec`) and `db_host`:
   ```bash
   docker compose logs api --since 15m --no-log-prefix \
     | grep '"status": 503' | grep -v '"/readyz"' | head -1 | jq
   ```
   Then use its `request_id` to find everything else logged for that request:
   ```bash
   docker compose logs api --since 15m | grep <request_id>
   ```
4. **Is the database container running?** `docker compose ps db`

**Fix:** bring the database back with `docker compose start db`. Don't restart the app.
The pool reconnects by itself: in the measured outage, healthy traffic was back within
about 20 seconds of the database starting. Restarting the app to fix a database problem
adds a second outage on top of the first.

**When it clears:** on its own, once the 5-minute ratio drops below 5%. `for` only delays
firing, not clearing. In the measured outage it cleared **2m13s** after the database
came back, because the 5m window was still full of errors from the outage until healthy
traffic diluted them.

**Acknowledge:** there's no Alertmanager, so nothing is sent anywhere and there's
nothing to acknowledge. The alert is only visible at http://localhost:9090/alerts.
Treat it as resolved when it leaves that page and `scoreboard_db_ready` is `1` on every
replica.

**Things that make this alert misleading:**

- **Docker healthchecks count toward the ratio.** During a database outage, Caddy stops
  forwarding most user requests, and most of what still reaches the app is `/readyz`
  healthchecks failing at about 0.2 req/s. In the measured outage, they're what took the
  ratio to 100%, and they're what kept traffic above the 0.1 req/s guard.
- **Outages shorter than about 3 minutes never fire.** A measured 1m55s outage peaked at
  a 2.5% error ratio.

<!-- AWS steps (RDS status, Logs Insights query) get added in 2.4 and 2.6. -->

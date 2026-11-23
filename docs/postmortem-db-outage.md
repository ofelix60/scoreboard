# Postmortem: database outage (induced drill)

**2026-11-23, AWS dev stack.** Caused on purpose to measure detection and recovery.
No real users were affected.

## Summary

I stopped the RDS instance while a loop sent steady traffic through the ALB. Requests
that need the database failed for **10m18s**. The alarm caught it after **7m38s**. The
service was back **1m56s** after I started the database, without restarting the app
or replacing the instance.

## Timeline (UTC)

Every time comes from a record, not a stopwatch: CloudTrail, RDS events, the alarm
history, and the request loop's log.

| Time | Event | Source |
|---|---|---|
| 19:08:31 | `StopDBInstance` | CloudTrail |
| 19:08:36 | First 503 on `/scores/top` | request loop |
| 19:09 | Target unhealthy (`UnHealthyHostCount` = 1) | CloudWatch |
| 19:14:52 | RDS reports "DB instance stopped" | RDS events |
| 19:16:14 | Alarm `scoreboard-dev-unhealthy-hosts` → **ALARM** | alarm history |
| 19:16:58 | `StartDBInstance` | CloudTrail |
| 19:18:52 | RDS reports "DB instance restarted" | RDS events |
| 19:18:54 | First 200 on `/scores/top` | request loop |
| 19:22:14 | Alarm → OK | alarm history |

| Measure | Time |
|---|---|
| Time to detect (first 503 → alarm) | 7m38s |
| Time to act (alarm → start the database) | 44s |
| Time to fix (start → first 200) | 1m56s |
| User-visible outage | 10m18s |

## What worked

- **The app failed fast and stayed alive.** `/scores/top` returned 503 after the
  pool's 2-second timeout instead of hanging. `/livez` answered 200 on all 334
  checks, so nothing tried to restart a healthy process.
- **The instance wasn't replaced.** The ASG uses EC2 health checks, not the load
  balancer's. With ELB health checks, a database outage looks like a broken instance:
  the ASG would have replaced it, and the replacement would have failed `/readyz` too.
  The ASG recorded no activity during the drill.
- **The pool reconnected by itself**, 2 seconds after RDS restarted.
- **The load balancer failed open.** With its only target unhealthy, the ALB kept
  sending traffic to it. Users got the app's 503 (182 `Target_5XX`, matching the loop
  exactly), not a load-balancer 502 (0 `ELB_5XX`).

## What didn't

- **Detection took most of the outage.** The alarm needs 5 one-minute datapoints, and
  CloudWatch publishes them about 2 minutes late. I chose that so one bad minute
  doesn't page anyone, and this is what it costs. The local Prometheus alert, with
  `for: 5m`, took 7m52s in the same kind of outage.
- **The alarm notifies nobody.** I knew it fired because I was polling it. With no SNS
  topic, the real time to detect is whenever someone happens to look.
- **RDS status lagged reality in both directions.** It reported "stopped" 6m16s after
  the app started failing. `aws rds wait db-instance-available` returned 1m35s after
  traffic had already recovered. Judge a dependency's health from the app's side, not
  from its provider's status.

## What I'd change

1. **Send the alarm somewhere** (an SNS topic to email or chat). Without that, the
   detection number above only exists because I was watching.
2. **Alarm on what users see.** A ratio of `HTTPCode_Target_5XX_Count` to
   `RequestCount` over 2–3 periods would fire sooner than a host-health count. The
   trade is more false alarms.
3. **Multi-AZ RDS** turns most database outages into a failover of a minute or two,
   for twice the database cost.

4. **Give this alarm a runbook entry.** [runbook.md](runbook.md) covers the local
   Prometheus alert, and its first checks (is the database reachable, which routes are
   failing) apply here too. The CloudWatch alarm doesn't have an entry of its own yet.

# Oracle Deadlock Lab (zero-login)

> 📖 **Companion post:** [ORA-00060 Deadlock: Find It, Fix It, Prevent It](https://uptimearchitect.com/blog/oracle-ora-00060-deadlock/)

Reproduce a **real ORA-00060 deadlock** on your own machine, read the **deadlock graph** Oracle writes,
and watch the one-line fix make it disappear — alongside the post **"ORA-00060 Deadlock: Find It, Fix It,
Prevent It."** No Oracle account, no license: it runs on the community **Oracle Database Free** image.

> ✅ **What it proves:** two sessions lock the same two rows in *opposite* order → a circular wait →
> Oracle auto-detects it within seconds and raises `ORA-00060` to one victim, rolling back **one
> statement** (not the transaction). The lab then prints the **`Deadlock graph`** from the trace file —
> the two TX enqueues and the two `UPDATE` statements that crossed. The `fixed` drill runs the *same*
> workload in a *consistent* order and deadlocks never happen.

> **No Diagnostics Pack, no `adrci`.** The lab reads the deadlock trace straight from the diagnostic
> `trace` directory (the path the alert log points at), so it works on the plain Free image.

## Prerequisites
- Docker + Docker Compose.

## Quick start
```bash
./run.sh up             # start Oracle Database Free (first run pulls the image + creates the DB)
./run.sh setup          # build the two-row table the deadlock needs
./run.sh drill-deadlock # induce ORA-00060 + print the deadlock graph
./run.sh drill-fixed    # same workload, consistent lock order -> NO deadlock
# ...or everything:
./run.sh all            # setup + both drills
```
If port 1521 is busy: `LAB_PORT=1530 ./run.sh up`.

## What each drill shows
- **`drill-deadlock`:** launches two SQL\*Plus sessions. Session A locks row `id=1` and holds it;
  session B locks `id=2` then reaches for `id=1`; A then reaches for `id=2` — the cycle closes and
  Oracle raises **`ORA-00060`** to whichever session it picks as victim (Oracle's choice, not yours).
  The driver treats that error as the **intended result** and prints the `Deadlock graph` + the two
  `UPDATE` statements from the trace.
- **`drill-fixed`:** the same two sessions, but both update in the **same order** (`id=1` then `id=2`).
  No cycle forms — B simply waits for A to commit, then proceeds. **No `ORA-00060`.** That's the fix:
  lock resources in a consistent, deterministic order.

> **Reading the graph:** each `TX-...` row is one transaction's enqueue. The two rows are the cycle —
> each session **holds** one (mode `X`, exclusive) and **waits** on the other. "Rows waited on" names
> the exact row, and the per-session `current SQL` shows the two statements that collided.

## Other commands
```bash
./run.sh sql       # SYSDBA SQL*Plus session inside the container (try @scripts/show-graph.sql)
./run.sh down      # stop & remove the container (keeps the data volume)
./run.sh destroy   # stop & remove the container AND the data volume
```

## Connection details
| | |
| --- | --- |
| Host / port | `localhost:${LAB_PORT:-1521}` |
| Pluggable DB | `FREEPDB1` |
| App user | `labuser` / `Lab_Passw0rd1` |
| SYS password | `Lab_Passw0rd1` |

Throwaway lab credentials — never reuse them anywhere real.

## Licensing
Pulls the community `gvenzl/oracle-free` image (Oracle Database Free, under Oracle's Free license for
development). It doesn't redistribute Oracle software — Docker pulls it for you. Oracle® is a registered
trademark of Oracle Corporation; this project is independent and not affiliated with or endorsed by Oracle.

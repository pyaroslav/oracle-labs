# Oracle Wait-Events Lab (zero-login)

> 📖 **Companion post:** [Oracle Wait Events, Decoded](https://uptimearchitect.com/blog/oracle-wait-events-decoded/)

Induce the wait events that carry real performance problems — on your own machine — and read each
one's signature in `v$session_event`, alongside the post **"Oracle Wait Events, Decoded."** No Oracle
account, no license: it runs on the community **Oracle Database Free** image (currently 26ai).

> ✅ **The method:** each drill flushes the buffer cache, runs a workload engineered to produce one
> specific wait event, then prints that session's `v$session_event` (idle events excluded) plus a
> before→after delta — so you see *cause → signature* in the exact views the post teaches.

> **Licensing note.** `v$session_event` / `v$system_event` are always available — **no Diagnostics
> Pack needed** (this lab uses the live wait interface, not AWR). It runs on the Free image; don't
> point it at a database you aren't licensed for.

## Prerequisites
- Docker + Docker Compose, with **~4 GB free** in the Docker engine.

## Quick start
```bash
./run.sh up            # start Oracle Database Free (first run pulls the image + creates the DB)
./run.sh setup         # build the throwaway schema (four tables, ~410 MB total)
./run.sh drill-seq     # 'db file sequential read'  — single-block index/rowid reads
./run.sh drill-scatter # 'db file scattered read'   — buffered multi-block full scan
./run.sh drill-direct  # 'direct path read'         — large scan bypassing the cache (into PGA)
./run.sh drill-commit  # 'log file sync'            — a row-by-row commit loop
# ...or everything:
./run.sh all           # setup + all four drills
```
If port 1521 is busy: `LAB_PORT=1530 ./run.sh up`. Everything runs *inside* the container via
`docker exec`, so you don't need a local Oracle client.

## What each drill proves
- **`drill-seq` → `db file sequential read`:** flushes the cache, then an index range scan + rowid
  lookups make every uncached block a **single-block (P3=1)** read. The session's `total_waits` for
  the event jumps by ~one per row touched.
- **`drill-scatter` → `db file scattered read`:** sets `_serial_direct_read=NEVER` (so a large serial
  full scan stays *buffered* instead of going direct), flushes, then full-scans a table. `physical
  reads cache` rises; each wait moved many blocks (P3>1), so the wait *count* is far below the block
  count.
- **`drill-direct` → `direct path read`:** forces a large scan to read straight into the PGA
  (`_serial_direct_read=ALWAYS`, plus a `PARALLEL` fallback). `physical reads direct` rises; the cache
  stays cold. (PX-slave reads accrue to the slave sessions, so the current-session delta reflects the
  serial pass.)
- **`drill-commit` → `log file sync`:** a PL/SQL loop of 50,000 single-row `INSERT` + `COMMIT` forces
  one synchronous LGWR write+post per commit. The session shows ~50,000 `log file sync` waits while
  instance-wide `log file parallel write` rises far less — proof that high LFS is a
  **commit-frequency** problem, not slow disk. Move the `COMMIT` outside the loop and it collapses to ~1.

> **On timing:** on fast local NVMe the wait *time* is small — what's deterministic is the *shape*
> (single-block vs multi-block vs direct, and ~50k commit waits), which is exactly what you learn to
> recognize. On production storage these same reads become the top timed event.

## Hidden parameters
`drill-scatter` and `drill-direct` set the undocumented `_serial_direct_read` to force a specific code
path for teaching. **That's fine in a throwaway Free lab; never set it in production.** The scripts say
so inline.

## Other commands
```bash
./run.sh sql       # SYSDBA SQL*Plus session inside the container
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
development). It doesn't redistribute Oracle software — Docker pulls it for you. Review Oracle's license
terms for your use. Oracle® is a registered trademark of Oracle Corporation; this project is independent
and not affiliated with or endorsed by Oracle.

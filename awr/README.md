# Oracle AWR Lab (zero-login)

> 📖 **Companion post:** [How to Read an AWR Report Without Drowning](https://uptimearchitect.com/blog/how-to-read-an-awr-report/)

Generate a **real AWR report** on your own machine and read it alongside the post
**"How to Read an AWR Report Without Drowning."** No Oracle account, no license — it runs on the
community **Oracle Database Free** image (currently 26ai).

> ✅ **Verified end-to-end** with `./run.sh all`: takes a baseline snapshot, runs a known CPU-bound
> workload, takes a second snapshot, and generates an AWR report in which **DB CPU is ~99% of DB time**
> and one `SELECT /*+ awr_demo */ …` statement tops *SQL ordered by CPU Time*.

> **Licensing note.** On the Free image `control_management_pack_access = DIAGNOSTIC+TUNING`, so AWR/ASH
> work for learning. In production on Enterprise Edition, AWR/ASH require the licensed **Diagnostics
> Pack** — don't run them on a database you aren't licensed for (use Statspack instead).

## Prerequisites
- Docker + Docker Compose, with **~4 GB free** in the Docker engine.

## Quick start
```bash
./run.sh up         # start Oracle Database Free (first run pulls the image + creates the DB)
./run.sh setup      # create the demo schema (incl. a ~1.4GB table for the I/O drill)
./run.sh drill      # CPU-bound: snapshot -> workload -> snapshot -> AWR report (awr-report.txt)
./run.sh drill-io   # I/O signature: flush + scan a big table -> AWR report (io-report.txt)
./run.sh drill-ash  # Active Session History report over the recent window (ash-report.txt)
# ...or everything:
./run.sh all        # setup + all three drills
```
If port 1521 is busy: `LAB_PORT=1530 ./run.sh up`. Everything runs *inside* the container via
`docker exec`, so you don't need a local Oracle client.

## What the drills do
- **`drill` (CPU-bound):** snapshot → a CPU-heavy statement (math over a generated row set the optimizer
  can't shortcut) → snapshot → AWR report (`awr-report.txt`). You'll see **DB CPU at ~99%** of DB time
  and the workload at the top of *SQL ordered by CPU Time*.
- **`drill-io` (I/O signature):** flushes the cache and full-scans a table bigger than the cache, so
  scans hit disk. The report (`io-report.txt`) shows high **physical reads**, a **direct path read**
  wait, and **`BIGTAB` as the #1 segment in *Segments by Physical Reads*** — the "what's doing the I/O"
  trail. (On fast local NVMe the I/O *wait time* stays small; on production storage it dominates.)
- **`drill-ash` (Active Session History):** runs a short workload, then generates an **ASH report**
  (`ash-report.txt`) — Top User Events, Top SQL, Top Sessions — the per-second view AWR averages away.

Open the reports and practice the reading method from the post: compute Average Active Sessions, read
Top Timed Events, then the right *SQL ordered by …* list.

## Other commands
```bash
./run.sh report    # re-print the last generated report
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

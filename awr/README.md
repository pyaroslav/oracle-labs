# Oracle AWR Lab (zero-login)

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
./run.sh up        # start Oracle Database Free (first run pulls the image + creates the DB)
./run.sh setup     # create a small demo schema
./run.sh drill     # snapshot -> CPU workload -> snapshot -> generate an AWR report
# ...or:
./run.sh all       # setup + drill
```
If port 1521 is busy: `LAB_PORT=1530 ./run.sh up`. Everything runs *inside* the container via
`docker exec`, so you don't need a local Oracle client.

## What `drill` does
1. Takes a baseline AWR snapshot.
2. Runs a deliberately CPU-bound statement twice (~20s) — math over a generated row set the optimizer
   can't shortcut, so it dominates the report.
3. Takes a closing snapshot.
4. Generates an AWR report for exactly that interval, saves it to **`awr-report.txt`**, and prints the
   sections that matter (header / DB Time, Load Profile, Top Timed Events, Top SQL).

Open `awr-report.txt` and practice the reading method from the post: compute Average Active Sessions,
read Top Timed Events (you'll see DB CPU on top), then *SQL ordered by CPU Time* (your workload is #1).

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

# Oracle RMAN Recovery Lab (zero-login)

> 📖 **Companion post:** [Oracle RMAN Recovery Runbook: Restore, Recover, Prove It](https://uptimearchitect.com/blog/oracle-rman-recovery-runbook/)

The first time you run an RMAN restore should **not** be in production. This lab lets you break a
throwaway Oracle database and recover it — for real — on the community **Oracle Database Free** image.
No Oracle account, no license, nothing but Docker.

> ✅ **Verified end-to-end in CI** with `./run.sh all`: it enables `ARCHIVELOG`, takes an RMAN backup,
> then runs three recoveries and **fails the run if any of them don't actually restore the data** — so a
> green check means the database really was broken and really came back.

## Prerequisites
- Docker + Docker Compose, with **~6 GB free** in the Docker engine (backups + a full restore need room).

## Quick start
```bash
./run.sh up               # start Oracle Database Free (first run pulls the image + creates the DB)
./run.sh all              # setup + all three recoveries end to end
# ...or step through them:
./run.sh setup            # ARCHIVELOG on, a demo tablespace + 100 rows, and an RMAN backup
./run.sh validate         # prove a restore would work — read-only, changes nothing
./run.sh drill-datafile   # delete a datafile from disk, then RESTORE + RECOVER it
./run.sh drill-pitr       # a bad DELETE, then point-in-time recovery to rewind past it
```
If port 1521 is busy: `LAB_PORT=1530 ./run.sh up`.

## What each drill proves
- **`validate`** — `RESTORE DATABASE VALIDATE CHECK LOGICAL` and `RESTORE ... PREVIEW`: confirms the
  backups a restore would need exist and aren't corrupt, **without restoring anything**. This is how you
  check a backup is recoverable *before* the worst day.
- **`drill-datafile`** — takes the demo datafile offline, **`rm`s it from disk**, then `RESTORE DATAFILE`
  + `RECOVER DATAFILE` and brings it back online. All 100 rows return. This is the single most common
  real recovery: one file, not the whole database.
- **`drill-pitr`** — inserts a "keeper" row, records the SCN, runs a `DELETE` that commits, then does
  database point-in-time recovery (`SET UNTIL SCN` → `RESTORE` → `RECOVER` → `OPEN RESETLOGS`) to rewind
  the database to **just before the delete**. The deleted rows come back. This is your answer to "someone
  ran a `DELETE` without a `WHERE`."

Each drill checks the row counts afterward and **exits non-zero if the data didn't come back** — the lab
refuses to pass on a recovery that didn't actually recover.

## Other commands
```bash
./run.sh sql        # SYSDBA SQL*Plus session inside the container
./run.sh down       # stop & remove the container (keeps the data volume)
./run.sh destroy    # stop & remove the container AND the data volume
```

## Connection details
| | |
| --- | --- |
| Host / port | `localhost:${LAB_PORT:-1521}` |
| CDB / PDB | `FREE` / `FREEPDB1` |
| App user | `labuser` / `Lab_Passw0rd1` |
| SYS password | `Lab_Passw0rd1` |

Throwaway lab credentials — never reuse them anywhere real.

## Licensing
Pulls the community `gvenzl/oracle-free` image (Oracle Database Free, under Oracle's Free license for
development). It doesn't redistribute Oracle software — Docker pulls it for you. Oracle® is a registered
trademark of Oracle Corporation; this project is independent and not affiliated with or endorsed by
Oracle.

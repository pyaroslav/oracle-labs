# Oracle HA Concepts Lab (zero-login)

A small, runnable lab that lets you *feel* the points from the post
**"The Oracle HA Decision Tree: RAC vs Data Guard vs Both"** on your own machine — no Oracle account
required. It runs on the community **Oracle Database Free** image from Docker Hub.

> ✅ **Verified end-to-end** with `./run.sh all` from a clean database: archivelog enabled, 1000-row
> demo schema, then all three drills pass (see *Expected output* below). Uses the **regular**
> `gvenzl/oracle-free` image — the `-slim` variant omits RMAN, which drills 2 and 3 need.

> **What this lab does and doesn't cover.** RAC (shared storage, cluster interconnect) and Data Guard
> (managed standby) are **Enterprise Edition** capabilities and aren't available on the Free image, so
> they can't run here. This lab covers the failure modes you *can* reproduce on a laptop — the ones the
> post argues are the most commonly mishandled:
> - **Human-error recovery** (Flashback) — the "replication is not a backup" lesson
> - **RMAN backup & restore** of a lost datafile
> - **Block-corruption detection & recovery**
>
> For real Data Guard switchover/failover, see the opt-in EE module in [`./dataguard/`](./dataguard/).

## Prerequisites

- Docker + Docker Compose.
- **~4 GB free memory in the Docker engine.** On Docker Desktop, set Settings → Resources → Memory to
  ~8 GB or more (the database needs a couple of GB to start, plus headroom to initialize).

## Quick start

```bash
# 1) Start the database (first run pulls the image and creates the DB — a few minutes)
./run.sh up

# 2) Enable archivelog + create the demo schema
./run.sh setup

# 3) Run the drills
./run.sh drill1     # human-error recovery (Flashback)
./run.sh drill2     # RMAN backup & restore of a lost datafile
./run.sh drill3     # block-corruption detection & recovery

# ...or everything end to end:
./run.sh all
```

If port 1521 is busy on your host, start it on another port: `LAB_PORT=1525 ./run.sh up`.
(The drills run *inside* the container via `docker exec`, so you don't need an Oracle client locally.)

## The drills, and what each one proves

### Drill 1 — Human-error recovery — *"replication is not a backup"*
Deletes all rows (committed) and then drops the table — two perfectly valid statements a Data Guard
standby would replicate within seconds. Recovers both **locally** with **Flashback Query**
(`AS OF TIMESTAMP`) and **Flashback Table … TO BEFORE DROP**. The point: a standby would *not* have
saved you here; point-in-time features and backups are what do.

### Drill 2 — RMAN backup & restore
Takes an RMAN backup, simulates media failure by taking a datafile offline and deleting it from disk,
then **restores and recovers just that datafile** while the rest of the database stays up. This is the
restore-drill discipline the post argues you should rehearse before you need it.

### Drill 3 — Block-corruption detection & recovery
Writes garbage into a single on-disk block, then **detects** it with `RMAN VALIDATE CHECK LOGICAL`
(also visible in `V$DATABASE_BLOCK_CORRUPTION`) and **repairs** it with block media recovery
(`RECOVER … BLOCK`) from the backup — no full restore required.

## Expected output

A successful `./run.sh all` ends like this (trimmed):

```text
>> DRILL 1: human-error recovery
   (new table — waiting 75s for it to age past Oracle's young-object flashback limit)
   ORDERS_BEFORE      1000
   AFTER_DELETE          0
   AFTER_FLASHBACK_QUERY_RECOVERY   1000
   AFTER_UNDROP       1000
>> DRILL 2: RMAN backup & restore of a lost datafile
   ... restore complete ... media recovery complete ...
   ORDERS_AFTER_RESTORE   1000
>> DRILL 3: block-corruption detection & recovery
   validate found one or more corrupt blocks      <- detected
   ... block restore complete ... media recovery complete ...
   Finished validate                              <- clean again
>> ALL DRILLS COMPLETE
```

> The 75-second wait in Drill 1 only happens on a brand-new database: Oracle refuses a flashback query
> against a table created moments ago (ORA-01466), so the lab lets the demo table age past that limit.
> On later runs the table is already old and there's no wait.

## Other commands

```bash
./run.sh status     # show DB name / role / open mode / log mode
./run.sh sql        # open a SYSDBA SQL*Plus session inside the container
./run.sh reset      # drop the demo objects (re-run setup to recreate)
./run.sh down       # stop & remove the container (keeps the data volume)
./run.sh destroy    # stop & remove the container AND the data volume
```

## Connection details

| | |
| --- | --- |
| Host / port | `localhost:${LAB_PORT:-1521}` |
| Pluggable DB (service) | `FREEPDB1` |
| App user | `labuser` / `Lab_Passw0rd1` |
| SYS password | `Lab_Passw0rd1` |

> These are throwaway lab credentials — never reuse them anywhere real.

## Troubleshooting

- **`./run.sh up` hangs or the container is "unhealthy".** First-time DB creation takes several minutes;
  watch progress with `docker logs -f ora-ha-lab`.
- **`Killed` during "uncompressing database data files".** The Docker engine ran out of memory — give it
  more (Docker Desktop → Resources → Memory), then `./run.sh destroy && ./run.sh up`.
- **Port already allocated.** Another service holds the port; use `LAB_PORT=<free-port> ./run.sh up`.

## Licensing note

This lab pulls the community `gvenzl/oracle-free` image, which packages **Oracle Database Free** (currently 26ai)
under Oracle's Free license for development use. It does not redistribute any Oracle software — Docker
pulls it for you. Review Oracle's license terms for your use.

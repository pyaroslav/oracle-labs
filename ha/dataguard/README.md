# Real Data Guard Lab (Enterprise Edition — opt-in)

This module stands up a genuine **primary + physical standby** so you can run the **switchover**,
**failover**, and **monitoring** drills from the post against real Data Guard. It needs Enterprise
Edition, which means an Oracle account.

> ⚠️ **These commands have NOT been executed or verified.** Data Guard requires Oracle Enterprise
> Edition (an Oracle account + license), which this project's automated testing does not cover. Treat
> this as a **guided walkthrough** assembled from standard Data Guard procedure: read it, adapt the
> hostnames/paths to your environment, and **verify each step in your own lab before relying on it.**
>
> By contrast, the zero-login Free lab in [`..`](..) **is** fully tested and CI-verified — it
> runs with a single `./run.sh all`.

## 0. Prerequisites

```bash
# Create a free account + accept the EE license at https://container-registry.oracle.com
docker login container-registry.oracle.com
docker compose up -d           # starts dg-primary (and an empty dg-standby shell)
```

Give the Docker engine ~8–10 GB RAM (Docker Desktop → Resources → Memory).

> **Heads-up on the standby container.** The EE image auto-creates a fresh `ORCLCDB` on
> `dg-standby`'s empty volume on first boot — you don't want that database, because the standby is
> built *from the primary* in step 2. Once the container is up, stop that instance, remove its
> spfile and control/data files, and restart it `NOMOUNT` from a minimal pfile
> (`DB_NAME=ORCLCDB`, `DB_UNIQUE_NAME=ORCLCDB_STBY`) — that NOMOUNT shell is what step 2's RMAN
> auxiliary connects to. (Alternatively, override the `standby` service's startup command to skip
> DB creation entirely.) The `DUPLICATE … FOR STANDBY` in step 2 then lays down the real standby.

## 1. Prepare the primary (on `dg-primary`)

```bash
docker exec -it dg-primary sqlplus / as sysdba
```
```sql
ALTER DATABASE FORCE LOGGING;
ALTER DATABASE FLASHBACK ON;                 -- enables painless reinstate after failover
-- Standby redo logs: one more group than online, same size
ALTER DATABASE ADD STANDBY LOGFILE SIZE 200M;   -- repeat to match (online groups + 1)
-- Data Guard parameters
ALTER SYSTEM SET DG_BROKER_START=TRUE;
ALTER SYSTEM SET STANDBY_FILE_MANAGEMENT=AUTO;
```

Add TNS entries (`$ORACLE_HOME/network/admin/tnsnames.ora`) on **both** containers for
`ORCLCDB` (→ dg-primary) and `ORCLCDB_STBY` (→ dg-standby), and ensure a static listener entry exists
so RMAN can connect to the standby instance before the database exists.

## 2. Create the standby with RMAN active duplication (on `dg-standby`)

Start the standby instance in NOMOUNT from a minimal pfile/spfile, then:

```bash
docker exec -it dg-standby rman \
  target sys/Lab_Passw0rd1@ORCLCDB \
  auxiliary sys/Lab_Passw0rd1@ORCLCDB_STBY
```
```rman
DUPLICATE TARGET DATABASE FOR STANDBY FROM ACTIVE DATABASE
  DORECOVER
  SPFILE
    SET DB_UNIQUE_NAME='ORCLCDB_STBY'
    SET FAL_SERVER='ORCLCDB'
    SET LOG_ARCHIVE_DEST_2='SERVICE=ORCLCDB ASYNC VALID_FOR=(ONLINE_LOGFILE,PRIMARY_ROLE) DB_UNIQUE_NAME=ORCLCDB'
  NOFILENAMECHECK;
```

## 3. Register both databases with the broker (on `dg-primary`)

```bash
docker exec -it dg-primary dgmgrl sys/Lab_Passw0rd1@ORCLCDB
```
```text
CREATE CONFIGURATION 'dg' AS PRIMARY DATABASE IS 'ORCLCDB' CONNECT IDENTIFIER IS ORCLCDB;
ADD DATABASE 'ORCLCDB_STBY' AS CONNECT IDENTIFIER IS ORCLCDB_STBY;
ENABLE CONFIGURATION;
SHOW CONFIGURATION;            -- wait for: Status SUCCESS
```

## 4. The drills (these mirror the post)

**Validate, then switch over (planned, lossless):**
```text
VALIDATE DATABASE 'ORCLCDB_STBY';     -- expect: Ready for Switchover: Yes
SWITCHOVER TO 'ORCLCDB_STBY';
SHOW CONFIGURATION;                   -- roles are now reversed; Status SUCCESS
```

**Fast-Start Failover (automatic):** run the Observer on a third location (here, the primary host is
fine for a lab):
```text
ENABLE FAST_START FAILOVER;
START OBSERVER;
```
Now kill the primary container (`docker stop dg-primary`) and watch the Observer promote the standby.
When the old primary returns, reinstate it in one step:
```text
REINSTATE DATABASE 'ORCLCDB';
```

**Monitor lag (the numbers that define your real RPO/RTO):**
```sql
SELECT name, value FROM v$dataguard_stats WHERE name IN ('transport lag','apply lag');
SELECT process, status, sequence# FROM gv$managed_standby WHERE process LIKE 'MRP%';
SELECT fs_failover_status, fs_failover_observer_present FROM v$database;
```

## Teardown

```bash
docker compose down -v
```

## Why this isn't a single script

Building a standby is environment-specific (hostnames, TNS, listener static registration, file paths),
and the value here is in *seeing and typing* the role transitions — which is exactly the muscle memory
the post argues you need before a real incident. Treat this as a guided rehearsal, not a black box.

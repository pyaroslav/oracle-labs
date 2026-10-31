# SYSDATE time-zone lab — SYSDATE is hours off after the move to the cloud

Companion to [SYSDATE Is Hours Off After the Move to the Cloud. Nothing
Errors.](https://uptimearchitect.com/blog/oracle-sysdate-timezone-cloud-migration/)

An on-prem database server runs in local time. The database moves to a cloud host or container that runs in UTC, and
`SYSDATE`, `SYSTIMESTAMP` and every `DEFAULT SYSDATE` column now return UTC. Nothing errors. New rows are 5 hours
(6 in winter) off from the rows before them, in the same column. `SYSDATE` comes from the operating system's clock and
time zone, not from the database. This lab "moves" one Oracle Database Free container by restarting the same instance
with a different `TZ`, then tries the fixes that don't work and the two that do.

## What it proves

| step | what you see | asserted |
| --- | --- | --- |
| **On-prem** (instance in America/Chicago) | the app's `SYSDATE` and a scheduler job's are Chicago time | both |
| **Moved** (same instance, UTC) | both jump to UTC; two orders placed seconds apart are stored 5 hours apart | all of it |
| **The scheduler after the move** | a 2am job with a time-zone region still runs at 2am Chicago | yes |
| **DBTIMEZONE set to Chicago** | `SYSDATE` doesn't change | yes |
| **A DBA shell with `TZ` set** | `sqlplus / as sysdba` shows Chicago; the app, at the same moment, UTC | both |
| **`TZ` on the listener only** | the app is still on UTC (26ai: server processes took the instance's `TZ`) | yes |
| **`CURRENT_DATE` instead of `SYSDATE`** | follows the client: UTC for a UTC client, Chicago with `ORA_SDTZ` set | both |
| **A job stored with a fixed `-05:00` offset** | after the November DST change it runs at 1am, not 2am | both jobs |
| **Fix 1: `TZ` for the instance** | app and job on Chicago time, listener untouched | both |
| **Fix 2: `TIME_AT_DBTIMEZONE=USER_SQL`** (26ai) | host still UTC; app, job and `DEFAULT SYSDATE` on Chicago time | all of it, and ORA-30079 first while a `TIMESTAMP WITH LOCAL TIME ZONE` column holds data |

## Run it

```bash
./run.sh up        # start Oracle Database Free (first run pulls the image)
./run.sh all       # setup -> onprem -> move -> traps -> fix_os -> fix_db, about 30 seconds
```

```bash
./run.sh setup     # schema TZ_APP (ORDERS with ORDER_DATE DEFAULT SYSDATE), two 2am jobs; resets the lab
./run.sh onprem    # instance started in America/Chicago
./run.sh move      # the same instance restarted in UTC
./run.sh traps     # DBTIMEZONE, a DBA shell, the listener, CURRENT_DATE, a fixed-offset job
./run.sh fix_os    # fix 1: TZ for the instance
./run.sh fix_db    # fix 2: DBTIMEZONE + TIME_AT_DBTIMEZONE=USER_SQL
./run.sh sql       # SQL*Plus as SYSDBA
./run.sh destroy   # remove the container and its volume
```

The steps build on each other; run them in order.

## Notes

- **Chicago's offset is read from the database each time** (`-5` until the first Sunday in November, `-6` after),
  so the checks hold all year. The numbers above are from a run in October.
- **How the lab "moves" the database:** it restarts the instance with `docker exec -e TZ=...`. On a real server the
  instance gets `TZ` from whatever starts it: the shell, a systemd unit, or Grid Infrastructure
  (`srvctl setenv database -db <db> -env "TZ=America/Chicago"`). That last part is not tested here.
- **The listener:** many runbooks say to set `TZ` for the listener as well. On 26ai in this lab it made no
  difference; the app's server processes took the instance's `TZ`. Older releases may behave differently, and
  setting it on both is harmless.
- **`SYSDATE_AT_DBTIMEZONE`** exists on 26ai Free but can't be changed here (`ORA-60490`); it is an Autonomous
  Database setting. `TIME_AT_DBTIMEZONE` is the one that works on 26ai (Oracle's reference: "available starting with Oracle AI Database 26ai"). The lab tests `USER_SQL` only.
- **`ALTER DATABASE SET TIME_ZONE`** fails with ORA-30079 while any `TIMESTAMP WITH LOCAL TIME ZONE` column holds
  data (an empty one doesn't block it), and takes effect when the PDB is reopened. Both fixes need a restart: the
  instance for fix 1, the PDB for fix 2.
- **Rows written between the move and the fix stay wrong.** Neither fix touches existing data; find the window and
  correct it once.

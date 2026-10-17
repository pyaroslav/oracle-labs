# ORA-01652 lab — a runaway query, not a small TEMP

Companion to [ORA-01652: Unable to Extend Temp Segment. Don't Just Add
Space.](https://uptimearchitect.com/blog/oracle-ora-01652-temp-space/)

`ORA-01652: unable to extend temp segment` says TEMP ran out. It doesn't say why. The reflex is to add a tempfile,
and that works when TEMP really is too small for normal work. When one query is asking for far more than any TEMP
could hold, more space only moves the failure. This lab builds that second case: a report whose join predicate was
lost in an edit, with `DISTINCT` added to hide the duplicates. Every one of the 50,000 open orders is paired with
every one of the 2,000 customers, and the `DISTINCT` has to deduplicate all 100 million combinations. Given enough
TEMP it would *finish*, and return 100 million rows instead of 50,000: the error is the only thing stopping a wrong
report from shipping.

## What it proves

The same report, on Oracle Database Free, with a TEMP tablespace that can't autoextend:

| TEMP | report | result | elapsed | TEMP used by the session |
| --- | --- | --- | --- | --- |
| 32 MB | join predicate missing | **ORA-01652** | 1.2 s | 31 MB |
| **320 MB (10x)** | join predicate missing | **ORA-01652 again** | 10.7 s | 318 MB |
| 32 MB | join predicate restored | **50,000 rows** | 0.1 s | **0 MB** |

`EXPLAIN PLAN` shows it before anything runs: a `MERGE JOIN CARTESIAN` feeding a `HASH UNIQUE`, with the
optimizer estimating 200M rows and a `TempSpc` of **8,445M**, about 8 GB of TEMP for a report that should return
50,000 rows. (The estimate is twice the real 100M because, without a histogram, the optimizer assumes half the
orders are OPEN; a quarter are.) The run asserts the
error on 32 MB, the Cartesian join in the plan, the error again on 320 MB, and 50,000 rows with no TEMP once the
join is back. (Elapsed times vary with the hardware; the run checks the outcomes, not the clock.)

It also shows why TEMP looks full when it isn't. Right after the failure:

| view | says |
| --- | --- |
| `V$TEMPSEG_USAGE` | 0 rows: the session that caused it is already gone |
| `V$TEMP_SPACE_HEADER` | 32 MB used, 0 MB free |
| `V$SORT_SEGMENT` | 0 MB in use |
| `DBA_TEMP_FREE_SPACE` | 31 MB free of 32 MB |

Oracle keeps TEMP extents allocated after a sort finishes and hands them to the next one. `V$TEMP_SPACE_HEADER`
counts them as used forever; `V$SORT_SEGMENT` and `DBA_TEMP_FREE_SPACE` show what's actually free.

## Run it

```bash
./run.sh up        # start Oracle Database Free (first run pulls the image)
./run.sh all       # setup -> before -> diagnose -> space -> fix
```

```bash
./run.sh setup     # TEMP_SMALL (32 MB, no autoextend), user TS, ORDERS and CUSTOMERS
./run.sh before    # the broken report on 32 MB; assert ORA-01652; TEMP through three views
./run.sh diagnose  # EXPLAIN PLAN for the report; assert MERGE JOIN CARTESIAN
./run.sh space     # add a 288 MB tempfile and run it again; watch it live; assert ORA-01652 again; ASH
./run.sh fix       # drop the extra tempfile; the report with the join restored; assert it fits
./run.sh sql       # SQL*Plus as SYSDBA
./run.sh destroy   # remove the container and its volume
```

## Notes

- **Recent releases name the culprit in the message.** Oracle Database Free (26ai, used here) prints the SQL ID
  and how much TEMP the session held, and says *grow* where older releases say *extend*: `... during operation with SQL ID : 249gkzhhu3cdk, temp space used by session : 31 (MB)`,
  and the same line goes to the alert log. On 19c the message is just `unable to extend temp segment by 128 in
  tablespace TEMP`. There, catch it live in `V$TEMPSEG_USAGE` (joined to `V$SESSION`), or after the fact in ASH,
  whose samples carry `TEMP_SPACE_ALLOCATED` (`./run.sh space` prints it). ASH is part of the Diagnostics Pack on
  Enterprise Edition.
- **`V$TEMPSEG_USAGE.SQL_ID` can point at the wrong statement.** Watching the report from a second session, the
  lab sees `SQL_ID` = SQL\*Plus's login query (`SELECT DECODE(USER, 'XS$NULL', ...`), while `SQL_ID_TEMPSEG` is the
  report that actually holds the TEMP. Use `SQL_ID_TEMPSEG`. The run asserts it matches the SQL ID in the error.
- **Adding space is still the right fix sometimes.** If the work is legitimate (a big index build, a nightly
  batch, more concurrent users), TEMP is simply too small. Check the plan first: a Cartesian join or a `TempSpc`
  estimate far beyond the result size points at the SQL.
- **Adding and removing a tempfile are both online.** `ALTER TABLESPACE ... ADD TEMPFILE` and `DROP TEMPFILE`
  need no restart. A BIGFILE tablespace holds exactly one file, so there you `RESIZE` the tempfile instead
  (`ADD TEMPFILE` fails with ORA-32771). This 26ai database creates new tablespaces as BIGFILE unless told
  otherwise (`DATABASE_PROPERTIES.DEFAULT_TBS_TYPE`), so the lab creates TEMP_SMALL as SMALLFILE to behave like 19c.
- **Autoextend doesn't fix a runaway query.** It lets the query fill the filesystem instead of the tablespace.
  Cap autoextending tempfiles with `MAXSIZE`. A user's own temporary tablespace (as TS has TEMP_SMALL here)
  keeps one application's runaway query from starving everyone else's sorts.
- **ORA-01652 on a permanent tablespace** (`... in tablespace USERS`) is a different problem: a `CREATE TABLE AS`,
  index build or `MOVE` building its new segment ran out of room. The tablespace named in the message tells you
  which one you have.
- Demo data is generic and invented.

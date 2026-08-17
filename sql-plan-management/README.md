# SQL Plan Management lab — watch a good plan regress, then watch a baseline hold it

Companion to [Oracle SQL Plan Management: Stop a Good Plan From Going
Bad](https://uptimearchitect.com/blog/oracle-sql-plan-management-baselines/).

An execution plan that was right yesterday can go wrong today without anyone touching the query — the
optimizer is free to change its mind when the statistics move. This lab makes that concrete and then stops
it. It builds a million-row `ORDERS` table with a heavily skewed, indexed `status` (exactly 500 `OPEN` rows
of 1,000,000) and a histogram, so `WHERE status = 'OPEN'` gets the cheap **index range scan**. It captures
that plan as an **accepted SQL plan baseline**, then drops the histogram to simulate the everyday stats
drift that breaks plans: with no histogram the optimizer assumes `1/NDV` — about a third of the table — and
now costs a **full table scan** as cheaper. The lab runs the same query twice and proves both outcomes. No
Oracle client needed — everything runs in the container.

## What it proves

| Baselines | What the optimizer would pick | Plan it actually runs | Buffers |
| --- | --- | --- | --- |
| **OFF** | full scan (no histogram → est. ~333K rows) | `TABLE ACCESS FULL` | ~14,300 |
| **ON** | full scan (same cost model) | `INDEX RANGE SCAN` — the accepted baseline | ~505 |

Same statement, same statistics, same session settings — the only difference is whether SQL plan baselines
are honored. With them off the plan regresses to a full scan; with them on the optimizer still *costs* the
full scan cheapest but is not allowed to run it, so it falls back to the accepted index plan (still
reproducible because the index exists) and `DBMS_XPLAN` reports the baseline was used. It's a test, not a
claim: the run **asserts** a full scan when unprotected and an index scan built from the baseline when
protected, and fails if either doesn't hold.

> **Why the histogram is the lever.** Dropping the histogram is a stand-in for everything that quietly
> re-costs a plan — a routine re-gather, data drift, an out-of-range predicate, an upgrade. The point isn't
> the histogram specifically; it's that the cost model changed underneath a plan that was already correct,
> and a baseline is what keeps the correct plan in force anyway.

## Run it

```bash
./run.sh up      # start the database (first run pulls the image)
./run.sh all     # setup -> capture -> regress -> nospm (assert regression) -> spm (assert save)
```

Or step through it:

```bash
./run.sh setup    # build the skewed table + index + histogram, gather stats
./run.sh capture  # run the query and capture its INDEX plan as an accepted baseline
./run.sh regress  # drop the histogram so the optimizer now prefers a full scan
./run.sh nospm    # show the plan with SQL plan baselines OFF (the regression: full scan)
./run.sh spm      # show the plan with SQL plan baselines ON  (the save: index, baseline used)
./run.sh sql      # SQL*Plus as SYSDBA -- read the plans yourself
```

## What you should see

```
>> REGRESSION: baselines OFF -- with the histogram gone, the optimizer picks a full scan
... TABLE ACCESS FULL | ORDERS | E-Rows 333K | A-Rows 500 | Buffers 14295 ...
   -> baselines off: TABLE ACCESS FULL (the plan regressed)

>> PROTECTED: baselines ON -- the accepted index plan is held despite the cheaper full-scan cost
... INDEX RANGE SCAN | ORDERS_STATUS_IX | Buffers 505 ...
   Note: - SQL plan baseline SQL_PLAN_... used for this statement
   -> baselines on: INDEX RANGE SCAN, built from the accepted SQL plan baseline

>> PASS: the plan regressed to a full scan when unprotected, and the baseline held the index plan when on.
```

## Try it yourself

Once it's up, `./run.sh sql` and inspect the baseline directly:

```sql
ALTER SESSION SET CONTAINER = FREEPDB1;

-- the baseline the capture created, and its state flags
SELECT sql_handle, plan_name, enabled, accepted, fixed, origin
FROM   dba_sql_plan_baselines
WHERE  sql_text LIKE '%shop.orders%';

-- the plan stored inside the baseline
SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY_SQL_PLAN_BASELINE(
  sql_handle => '&sql_handle', format => 'BASIC'));

-- toggle it live: FALSE -> full scan, TRUE -> index + "SQL plan baseline used" in the Note
ALTER SESSION SET STATISTICS_LEVEL = ALL;
ALTER SESSION SET optimizer_use_sql_plan_baselines = TRUE;
SELECT /*+ GATHER_PLAN_STATISTICS */ SUM(amount) FROM shop.orders WHERE status = 'OPEN';
SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY_CURSOR(FORMAT => 'ALLSTATS LAST'));
```

## Notes

- The lab captures the baseline with **automatic capture** (`OPTIMIZER_CAPTURE_SQL_PLAN_BASELINES`), running
  the statement twice so its first plan is auto-accepted. `DBMS_SPM.LOAD_PLANS_FROM_CURSOR_CACHE` is the
  other common path, but a `SORT AGGREGATE` cursor can report `PLAN_HASH_VALUE = 0` in the cursor cache, so
  the loader has nothing to copy — automatic capture is the reliable way to seed this one.
- Baselines live in the SQL Management Base (`SYSAUX`), not in the schema, so dropping the `SHOP` user does
  not remove them. `setup` clears any baseline from a previous run so `./run.sh all` is deterministic.

## Cleanup

```bash
./run.sh down     # stop the container, keep the data volume
./run.sh destroy  # remove everything including the volume
```

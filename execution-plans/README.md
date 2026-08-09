# Execution-plans lab — watch a misestimate pick the wrong plan, then fix it

Companion to [Oracle Execution Plans, Decoded: The One Number That
Matters](https://uptimearchitect.com/blog/oracle-execution-plans-decoded/).

A slow query is almost always one wrong cardinality estimate that the rest of the plan trusted. This lab
makes that concrete and provable: it builds a million-row table where `status = 'OPEN'` is deliberately
rare (500 rows), gathers statistics **without a histogram**, and reads the real execution plan. The
optimizer, assuming the two status values split the table evenly, estimates ~500,000 rows for `OPEN` and
**full-scans**. Then the lab gathers a histogram, re-runs, and the plan **flips to an index range scan**
with the estimate corrected. No Oracle client needed — everything runs in the container.

## What it proves

| Phase | Statistics | What the optimizer believes | Plan it picks |
| --- | --- | --- | --- |
| **Before** | no histogram on `status` | `OPEN` ≈ 500,000 rows (half the table) | `TABLE ACCESS FULL` |
| **After** | frequency histogram on `status` | `OPEN` ≈ 500 rows (the truth) | `INDEX RANGE SCAN` |

The run reads the plan with `DBMS_XPLAN.DISPLAY_CURSOR(FORMAT => 'ALLSTATS LAST')` and **asserts** it:
before the fix it fails unless there's a full scan whose **E-Rows is at least 20× A-Rows** (the
misestimate is real); after the fix it fails unless the plan is an **index range scan with E-Rows ≈ A-Rows**
(the estimate was corrected and the plan changed). The whole before/after is a test, not a claim.

## Run it

```bash
./run.sh up      # start the database (first run pulls the image)
./run.sh all     # setup -> before (assert misestimate) -> fix -> after (assert corrected)
```

Or step through it:

```bash
./run.sh setup   # build the skewed 1,000,000-row table, stats without a histogram
./run.sh before  # show the plan the optimizer picks with no histogram (full scan)
./run.sh fix     # gather the histogram on the skewed column
./run.sh after   # show the corrected plan (index range scan)
./run.sh sql     # SQL*Plus as SYSDBA -- read the plans yourself
```

## What you should see

```
>> BEFORE: no histogram — the optimizer assumes 'OPEN' matches half the table
... TABLE ACCESS FULL | ORDERS | E-Rows 500K | A-Rows 500 ...
   -> E-Rows=500000 vs A-Rows=500 : over-estimated 1000x, so it FULL-scanned

>> AFTER: with the histogram, the optimizer knows 'OPEN' is rare
... INDEX RANGE SCAN | ORD_STATUS_IX | E-Rows 500 | A-Rows 500 ...
   -> E-Rows=500 vs A-Rows=500 : estimate now matches reality (1x), so it used the INDEX

>> PASS: misestimate reproduced (1000x over -> full scan) and the histogram corrected it (index range scan, E~=A).
```

## Try it yourself

Once it's up, `./run.sh sql` and read the plan the way you would in a real investigation — run the query
with the hint, then pull the plan with actual row counts:

```sql
ALTER SESSION SET CONTAINER = FREEPDB1;
ALTER SESSION SET STATISTICS_LEVEL = ALL;

SELECT /*+ GATHER_PLAN_STATISTICS */ SUM(amount) FROM shop.orders WHERE status = 'OPEN';
SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY_CURSOR(FORMAT => 'ALLSTATS LAST'));
```

Compare the `E-Rows` and `A-Rows` columns on the row-source lines. Where they diverge is where the
optimizer was wrong — and, here, why it chose the plan it did.

## Cleanup

```bash
./run.sh down     # stop the container, keep the data volume
./run.sh destroy  # remove everything including the volume
```

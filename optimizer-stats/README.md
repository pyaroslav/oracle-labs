# Optimizer-stats lab — watch correlated columns wreck an estimate, then fix it

Companion to [Oracle Optimizer Statistics,
Demystified](https://uptimearchitect.com/blog/oracle-optimizer-statistics-demystified/).

The optimizer assumes columns are independent and multiplies their selectivities. When two columns are
actually correlated, that multiplication produces a large **under**-estimate — and a plan built for far
fewer rows than really match. This lab makes it concrete: it builds a million-row table where `model`
determines `make` (100 models, 50 makes, 2 models per make), joins it to an orders table, and runs
`WHERE make = 'MAKE_025' AND model = 'MODEL_050'`. The optimizer multiplies `1/50 × 1/100`, expects ~200
rows, and picks a **nested loop** join — but ~10,000 rows match, so the nested loop probes the orders index
10,000 times. Then the lab creates an **extended statistic** on the `(make, model)` column group,
re-gathers, and the estimate snaps to ~10,000, flipping the plan to a **hash join**. No Oracle client
needed — everything runs in the container.

## What it proves

| Phase | Statistics | What the optimizer believes | Join it picks |
| --- | --- | --- | --- |
| **Before** | no column group | make & model independent → ~200 rows | `NESTED LOOPS` |
| **After** | `(make, model)` extended stat | ~10,000 rows (the truth) | `HASH JOIN` |

The run reads the plan with `DBMS_XPLAN.DISPLAY_CURSOR(FORMAT => 'ALLSTATS LAST')` and **asserts** it:
before the fix it fails unless there's a nested loop whose **A-Rows is at least 10× E-Rows** (the
under-estimate is real); after the fix it fails unless the plan is a **hash join with E-Rows ≈ A-Rows** (the
column group corrected the estimate and the plan changed). It's a test, not a claim.

> **Why the lab turns off adaptive plans.** Modern Oracle has *adaptive plans*, which would spot the wrong
> row count at run time and switch the nested loop to a hash join on its own — masking exactly the effect
> this lab is about. The probe sets `optimizer_adaptive_plans = false` so you can see what the **estimate
> alone** decides. That's the real lesson: adaptive plans are a runtime safety net, not a substitute for
> statistics that are right in the first place.

## Run it

```bash
./run.sh up      # start the database (first run pulls the image)
./run.sh all     # setup -> before (assert under-estimate) -> fix -> after (assert corrected)
```

Or step through it:

```bash
./run.sh setup   # build the correlated tables, stats without a column group
./run.sh before  # show the plan with make & model treated as independent (nested loop)
./run.sh fix     # create + gather the (make, model) column group
./run.sh after   # show the corrected plan (hash join)
./run.sh sql     # SQL*Plus as SYSDBA -- read the plans yourself
```

## What you should see

```
>> BEFORE: no column group — optimizer multiplies selectivities and under-counts the filter
... NESTED LOOPS ... TABLE ACCESS FULL | CARS | E-Rows 200 | A-Rows 10000 ...
   -> CARS filter E-Rows=200 vs A-Rows=10000 : under-counted 50x, so it chose a NESTED LOOP

>> AFTER: with the column group, the optimizer knows make & model travel together
... HASH JOIN ... TABLE ACCESS FULL | CARS | E-Rows 10000 | A-Rows 10000 ...
   -> CARS filter E-Rows=10000 vs A-Rows=10000 : estimate now matches reality (1x), so it HASH-joined

>> PASS: under-estimate reproduced (50x under -> nested loop) and the column group corrected it (hash join, E~=A).
```

## Try it yourself

Once it's up, `./run.sh sql` and confirm the column group exists and see the corrected estimate:

```sql
ALTER SESSION SET CONTAINER = FREEPDB1;

-- the extended statistic the fix created
SELECT extension_name, extension FROM dba_stat_extensions WHERE table_name = 'CARS';

ALTER SESSION SET STATISTICS_LEVEL = ALL;
ALTER SESSION SET optimizer_adaptive_plans = FALSE;
SELECT /*+ GATHER_PLAN_STATISTICS */ SUM(o.amount)
FROM   sales.cars c, sales.orders o
WHERE  c.id = o.car_id AND c.make = 'MAKE_025' AND c.model = 'MODEL_050';
SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY_CURSOR(FORMAT => 'ALLSTATS LAST'));
```

## Cleanup

```bash
./run.sh down     # stop the container, keep the data volume
./run.sh destroy  # remove everything including the volume
```

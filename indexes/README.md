# Indexes lab — when they help, when they hurt

Companion to [Oracle Indexes: When They Help, When They Hurt, and How to
Tell](https://uptimearchitect.com/blog/oracle-indexes-help-vs-hurt/).

"Add an index" is the reflex fix for a slow query, and half the time it's the wrong one — a low-selectivity
index the optimizer ignores (so it did nothing but slow your writes), or one you *forced* that reads more than
the full scan it replaced. An index isn't fast or slow; it's fast or slow **for a given query's selectivity**,
and the execution plan is where you find out which.

This lab builds a 1,000,000-row `ORDERS` table — `customer_id` with ~100k distinct values, `status` heavily
skewed (950,000 `SHIPPED` / 49,000 `OPEN` / 1,000 `PENDING`) — indexes both, gathers a frequency histogram on
`status`, and runs five queries. It reads the real access operation and buffer gets from each and **asserts** the
outcome.

## What it proves

| Query | Plan | Buffer gets |
| --- | --- | --- |
| `customer_id = 500` (natural) | **INDEX RANGE SCAN** | **14** |
| `customer_id = 500` (`FULL` hint) | TABLE ACCESS FULL | **17,834** |
| `status = 'SHIPPED'` — 95% (natural) | **TABLE ACCESS FULL** | 17,818 |
| `status = 'SHIPPED'` (`INDEX` hint) | INDEX RANGE SCAN | **19,459** |
| `status = 'PENDING'` — 0.1% (natural) | **INDEX RANGE SCAN** | **24** |

Three lessons, all asserted:

1. **The right index is a huge win.** The selective `customer_id` query reads **14 buffers** with the index
   versus **17,834** as a full scan — about **1,270× less work**.
2. **The optimizer correctly ignores a useless index.** For `SHIPPED` (95% of rows) it picks a full scan, not
   `idx_status` — reading almost every row through an index would be slower than just scanning the table. The
   *same* index is used for `PENDING` (0.1%). Selectivity, not the index's existence, decides.
3. **A forced index can actively hurt.** Made to use `idx_status` for `SHIPPED`, the query reads **19,459**
   buffers — *more* than the 17,818 of the full scan it replaced. That's the "I added an index and it got slower"
   story, measured.

If any of those flips, the run fails.

## Run it

```bash
./run.sh up      # start the database (first run pulls the image)
./run.sh all     # setup -> prove
```

```bash
./run.sh setup   # build the 1M-row table, both indexes, and stats (frequency histogram on status)
./run.sh prove   # run the five queries; assert help / ignore / hurt from plans + buffer gets
./run.sh sql     # SQL*Plus as SYSDBA -- run EXPLAIN PLAN / DBMS_XPLAN yourself
```

## Notes

- **The histogram on `status` is essential.** Without it the optimizer assumes the three status values are
  uniform (1/3 each) and can't tell the common value from the rare one, so it can't make the right call for
  either. `setup` gathers `FOR COLUMNS status SIZE 254`, which builds a frequency histogram (three distinct
  values) so the optimizer knows `SHIPPED` is 95% and `PENDING` is 0.1%.
- **The wide `filler` column is deliberate** — it makes the table ~120MB so a full scan is genuinely expensive,
  which is what makes the selective-index win (14 vs 17,834) dramatic instead of marginal.
- **Buffer gets, not time.** The lab compares logical reads (buffer gets) from `V$SQL`, which are deterministic
  and don't depend on caching or hardware — the same reason the other performance labs use them.
- **`INDEX RANGE SCAN` + `TABLE ACCESS BY INDEX ROWID`** is the normal shape for a non-covering index: the index
  finds the rowids, then the table is visited for the other columns. A covering (index-only) scan avoids the
  table visit — one reason the exact columns in an index matter.
- Demo data is generic and invented — nothing sensitive.

## Cleanup

```bash
./run.sh down     # stop the container, keep the data volume
./run.sh destroy  # remove everything including the volume
```

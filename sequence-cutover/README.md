# Sequence-cutover lab — the migration that passes every check, then fails the first insert

Companion to [Cutover Went Perfectly. The First New Order Failed With
ORA-00001.](https://uptimearchitect.com/blog/oracle-sequence-cutover-ora-00001/).

Many migrations load the schema once (tables **and** sequences), keep the source running, and then refresh
just the **table data** at cutover. Row counts match, data checks pass, the app goes live, and the first insert
fails with `ORA-00001: unique constraint violated`. The sequence on the target was copied at the initial load
and never moved, so it hands out keys that already exist. This lab reproduces that, shows the check that would
have caught it, and fixes it.

## What it proves

| step | source `SHOP` | target `NEWSHOP` | `NEWSHOP.ORDER_SEQ` next |
| --- | --- | --- | --- |
| initial load: `expdp SCHEMAS=shop` → `impdp REMAP_SCHEMA` | 9,000 rows, max(id) 9,000 | 9,000 rows, max(id) 9,000 | 9,001 |
| source keeps taking orders | 10,000 rows, max(id) 10,000 | (unchanged) | 9,001 |
| final refresh: `CONTENT=DATA_ONLY`, `TABLE_EXISTS_ACTION=TRUNCATE` | 10,000 | **10,000 rows, max(id) 10,000** | **9,001** |
| first insert on the new system | | **ORA-00001** | |
| `ALTER SEQUENCE … RESTART START WITH 10001` | | insert succeeds, id **10,001** | 10,002 |

The pre-go-live check (`./run.sh check`) compares each sequence's next value with the highest key in the table
it feeds and reports `NEWSHOP.ORDER_SEQ next=9001 max(ORDERS.ID)=10000 BEHIND by 1000`. The run fails if the
collision doesn't reproduce, if the check misses it, or if the fix doesn't let the same insert through.

## Run it

```bash
./run.sh up       # start Oracle Database Free (first run pulls the image)
./run.sh all      # setup -> initial -> drift -> final -> cutover -> fix
./run.sh check    # the pre-go-live sequence check on its own
```

## Notes

- **Why a data-only refresh.** Refreshing tables with `CONTENT=DATA_ONLY` (or a final GoldenGate/insert-select
  catch-up, or a re-load of "just the data") is common precisely because it leaves the target's objects, grants
  and code alone. Sequences are objects, not data, so they are left alone too.
- **Cache makes it worse to test.** With a cached sequence, Data Pump exports the sequence's `LAST_NUMBER`
  (the high-water mark of its cache), not the last value actually used. In a first run of this lab with
  `CACHE 20` on 26ai (which grows sequence caches dynamically), the source had used 9,000 values but the target
  sequence started at 22,221: headroom that can hide the problem in a small rehearsal and still collide in
  production. The lab uses `NOCACHE` so the numbers are exact.
- **Every retry burns a value.** A failed insert still consumes `NEXTVAL`, so an app that retries walks the
  sequence forward one collision at a time; here it would fail 1,000 times before reaching a free key.
- **The fix.** `ALTER SEQUENCE … RESTART START WITH n` (18c+) resets the sequence in place, keeping grants and
  dependents. On older releases, temporarily change `INCREMENT BY`, call `NEXTVAL` once, and set it back, or
  drop and recreate the sequence (and re-grant). Identity columns: `ALTER TABLE … MODIFY id GENERATED … AS
  IDENTITY (START WITH LIMIT VALUE)`.
- **The real fix is the runbook.** Resync every sequence (or re-export sequences with the final data) as an
  explicit cutover step, and run the check before opening the doors. Demo data is generic and invented.

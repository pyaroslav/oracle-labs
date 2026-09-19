# Snapshot-too-old lab — reproduce ORA-01555, then make it impossible

Companion to [ORA-01555 Snapshot Too Old: Reproduce It, Then Make It
Impossible](https://uptimearchitect.com/blog/oracle-ora-01555-snapshot-too-old/).

`ORA-01555: snapshot too old` is one of the most-Googled Oracle errors, and one of the most misunderstood — it
is not a bug in your query, it is your query being *right*. To stay read-consistent, a long-running query must
see data as of the moment it started, and Oracle rebuilds older versions of changed blocks from **undo**. When
heavy DML churns through an undersized undo tablespace and overwrites the undo that query still needs, the read
can no longer be made consistent, and Oracle raises ORA-01555 rather than return wrong data. This lab forces
exactly that, then fixes it — with the *same* query proving the difference.

## What it proves

The identical query — a full scan of a 20,000-row table, fetched row by row across a burst of DML — run twice:

| undo configuration | the query |
| --- | --- |
| **25 MB, no autoextend, `RETENTION NOGUARANTEE`, `undo_retention=1`** | **fails with ORA-01555** |
| **300 MB, `RETENTION GUARANTEE`, `undo_retention=1200`** | **reads all 20,000 rows** |

Both runs do the same thing: open a cursor, fetch one row to pin the read-consistent snapshot, then rewrite every
row 12 times and commit — churning far more undo than the small tablespace holds. On the weak config the undo the
cursor needs is overwritten and the very next fetch dies with ORA-01555. On the fixed config the undo is
preserved, so the same query reads all 20,000 rows. If the failure doesn't reproduce, or the fix doesn't cure it,
the run fails.

## Run it

```bash
./run.sh up        # start Oracle Database Free (first run pulls the image)
./run.sh all       # setup -> reproduce -> fix
```

```bash
./run.sh setup     # build the 20,000-row table + the weak undo config
./run.sh reproduce # run the query under the weak config; assert ORA-01555
./run.sh fix       # apply the fix, re-run the SAME query; assert it completes
./run.sh sql       # SQL*Plus as SYSDBA
```

## Notes

- **The error is read consistency, not a resource leak.** The query pins its snapshot at the SCN it started; each
  block it later reads that was changed after that SCN must be reconstructed from undo. ORA-01555 means that undo
  is gone — overwritten because it had already "expired" (older than `undo_retention`) and the churn needed the
  space.
- **`RETENTION GUARANTEE` is the real fix, with a trade-off.** It tells Oracle to *never* overwrite unexpired
  undo — so a long query stays consistent — but it means a DML that can't find undo space will fail with
  `ORA-30036` instead. That is the right trade for reporting/ETL windows; size the undo tablespace for the
  workload so DML doesn't starve.
- **`undo_retention` is a target, not a guarantee — until you add GUARANTEE.** Without guarantee, Oracle treats
  `undo_retention` as best-effort and will reuse unexpired undo under space pressure (exactly what breaks the long
  query). With guarantee, `undo_retention` becomes a floor.
- **Why the churn must not use `ORDER BY`.** The cursor is a plain full scan so rows are fetched lazily, block by
  block, *after* the churn has overwritten the undo. An `ORDER BY` would sort (and read) all rows up front, before
  the churn, and never hit the error — a good reminder that when a query reads its blocks matters.
- **The knobs are tuned to be deterministic:** 25 MB is big enough for one full-table update's undo (so the churn
  doesn't just fail with ORA-30036) but small enough that 12 rounds wrap it many times over and overwrite the
  snapshot. Demo data is generic and invented.

## Cleanup

```bash
./run.sh down     # stop the container, keep the data volume
./run.sh destroy  # remove everything including the volume
```

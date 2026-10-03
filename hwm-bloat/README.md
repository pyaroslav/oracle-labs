# High-water mark bloat lab — delete 99% of the rows, watch the full scan not care

Companion to [You Deleted 99% of the Rows. The Full Scan Didn't Get Any
Faster.](https://uptimearchitect.com/blog/oracle-high-water-mark-bloat/).

A full table scan reads every block below the table's **high-water mark** (HWM) — the boundary of the space the
segment has ever used. `DELETE` removes rows, but it does not move the HWM, so a table that has been emptied by
99% still costs a full scan almost exactly what it cost when it was full. This lab measures that, then lowers
the HWM with `SHRINK SPACE` and measures again.

## What it proves

The same full scan (`SELECT /*+ FULL(t) */ COUNT(pad) FROM hwm.t`), measured in consistent gets from
`V$MYSTAT`, at three points:

| state | rows | full-scan consistent gets | blocks below HWM | allocated blocks |
| --- | --- | --- | --- | --- |
| loaded | 200,000 | 6,074 | 6,175 | 6,272 |
| **after `DELETE` of 99% + commit** | **2,000** | **6,074** | **6,175** | **6,272** |
| after `ALTER TABLE … SHRINK SPACE` | 2,000 | **64** | **62** | **72** |

1% of the rows cost 100% of the work until the HWM came down; after the shrink, the scan's cost follows the data.
The run asserts the delete leaves the scan at ≥ 90% of the baseline, the shrink brings it to ≤ 5%, and every
remaining row survives. (Exact numbers can vary slightly by release; the ratios are what the run checks.)

## Run it

```bash
./run.sh up       # start Oracle Database Free (first run pulls the image)
./run.sh all      # setup -> bloat -> fix
```

```bash
./run.sh setup    # load 200,000 rows and take the baseline measurement
./run.sh bloat    # delete 99%; assert the full scan still does ~the same work
./run.sh fix      # SHRINK SPACE; assert the scan drops to ~1%
./run.sh sql      # SQL*Plus as SYSDBA
```

## Notes

- **Finding bloated tables.** Compare what the table occupies with what its rows need, from fresh statistics:
  `blocks` vs `num_rows * avg_row_len / (block_size * 0.9)` in `DBA_TABLES`. In the lab, after the delete:
  6,175 blocks for rows that need about 58 — 99% wasted.
- **`SHRINK SPACE` needs ASSM and row movement.** It works on tables in automatic segment space management
  tablespaces (the default), moves rows (so `ENABLE ROW MOVEMENT` first), keeps indexes usable, and is online
  apart from a brief lock at the end. `SHRINK SPACE COMPACT` does the row movement without the final HWM reset,
  so you can split the work: compact during the day, finish with a quick `SHRINK SPACE` later.
- **Alternatives.** `ALTER TABLE … MOVE ONLINE` (12.2+) rebuilds the segment and maintains indexes; a plain
  `MOVE` leaves indexes `UNUSABLE` until rebuilt. `TRUNCATE` resets the HWM instantly but removes every row.
- **Index scans don't care; full scans do.** A lookup by primary key reads a handful of blocks either way. The
  bloat bites full scans, fast full index scans on equally bloated indexes, and anything that reads "the whole
  table" — reports, aggregates, and statistics gathering.
- **Inserts reuse the free space.** Conventional inserts fill the emptied blocks over time, so bloat matters most
  for tables that were purged and won't grow back. Direct-path (`APPEND`) inserts always go above the HWM and
  never reuse it. Demo data is generic and invented.

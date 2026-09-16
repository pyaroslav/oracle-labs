# Bind variables lab — the hard-parse storm

Companion to [Bind Variables: The Hard-Parse Storm That Melts Your Shared
Pool](https://uptimearchitect.com/blog/oracle-bind-variables-hard-parse/).

"It's just a `SELECT` by id" — run it a thousand times with the value pasted straight into the SQL text and
you've asked Oracle to parse a thousand *different* statements. Each one is a hard parse, a new cursor in the
library cache, and a few more KB of shared pool that no other query will ever reuse. Do it with a **bind
variable** and it's one statement, parsed once, executed a thousand times. This lab runs both and measures the
difference from `V$SQL` and `V$MYSTAT` — no timings, just counts that come out the same on every machine.

## What it proves

The same logical query — `select count(*) from bindlab.widgets where id = <n>` — run 1,000 times:

| 1,000 runs of one query | cursors in `V$SQL` | hard parses | shared pool |
| --- | --- | --- | --- |
| with **literals** (`... id = '||i`) | **1,000** | **1,001** | **~38 MB** |
| with a **bind** (`... id = :b` using i) | **1** | **1** | **~39 KB** |

The bind cursor shows **1,001 executions** — every run reused the one cursor. Three facts, all asserted:

1. **Literals multiply.** Every distinct value is a distinct SQL text, so 1,000 runs leave ~1,000 parent cursors
   and ~1,000 hard parses — CPU spent parsing, plus a mutex/latch on the library cache every time.
2. **The bind collapses it to one.** A single cursor, one hard parse, and 1,000 executions. Same rows back.
3. **The shared pool pays for it.** The literal cursors burn ~1,000× the memory (~38 MB vs ~39 KB here) on
   cursors that will never be reused — the classic "shared pool / library cache" pressure and `cursor: pin S`
   contention behind a mysteriously CPU-bound, non-scaling OLTP database.

If literals don't explode into ~1,000 cursors, or the bind doesn't collapse to one, the run fails.

## Run it

```bash
./run.sh up      # start Oracle Database Free (first run pulls the image)
./run.sh all     # setup -> prove
```

```bash
./run.sh setup   # build the 1,000-row bindlab.widgets table
./run.sh prove   # run both loops; assert cursor + hard-parse counts from V$SQL / V$MYSTAT
./run.sh sql     # SQL*Plus as SYSDBA -- inspect V$SQL yourself
```

## Notes

- **Counts, not milliseconds.** The lab reads the number of cursors (`V$SQL`), the session hard-parse delta
  (`V$MYSTAT` `parse count (hard)`), executions, and `sharable_mem` — all deterministic and hardware-independent,
  the same reason the other performance labs use logical reads instead of wall-clock time.
- **Each drill flushes the shared pool first**, then does a tiny *bound* warm-up query so the before/after
  hard-parse delta reflects only the loop, not one-time post-flush dictionary reparsing. Without that warm-up the
  bind's delta picks up ~30 recursive parses from the flush and overstates its cost.
- **The literal loop uses `EXECUTE IMMEDIATE '... id = '||i`** to force a fresh SQL text each iteration — exactly
  what string-concatenated SQL in an application does. The bind loop uses `EXECUTE IMMEDIATE '... id = :b' USING
  i`; ordinary static PL/SQL (`... where id = i`) binds automatically and behaves the same way.
- **This is not SQL injection's cousin by accident.** Bind variables are also the single most important defense
  against SQL injection — the same habit that saves your shared pool protects your data.
- Demo data is generic and invented — nothing sensitive.

## Cleanup

```bash
./run.sh down     # stop the container, keep the data volume
./run.sh destroy  # remove everything including the volume
```

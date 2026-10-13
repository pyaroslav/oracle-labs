# "Checkpoint not complete" lab — redo logs too small for the write rate

Companion to [Checkpoint Not Complete: Every Commit Waits, and the SQL Is
Fine](https://uptimearchitect.com/blog/oracle-checkpoint-not-complete/).

Oracle writes every change to the **online redo logs** in a circle. Before the log writer can reuse a log, the
checkpoint that covers it must finish: DBWR has to write every dirty block whose changes live in that log. If the
logs are small and the write rate is high, the log writer laps the checkpoint, and **every session that wants to
generate redo stops** on `log file switch (checkpoint incomplete)` while the alert log prints
`Checkpoint not complete`. This lab reproduces that on the image's own default layout (two 20 MB groups), then
resizes the logs online and runs the identical burst again.

## What it proves

The same workload (`UPDATE` of all 100,000 rows of ~1 KB, one commit, ~225 MB of redo), measured from
`V$SYSTEM_EVENT`, `V$LOG_HISTORY` and the alert log:

| redo layout | elapsed | log switches | `log file switch (checkpoint incomplete)` | alert log `Checkpoint not complete` |
| --- | --- | --- | --- | --- |
| **2 x 20 MB** (image default) | **14.1 s** | 12 | **12 waits, 11.9 s** | **12 lines** |
| 3 x 512 MB | **1.9 s** | 0 | 0 | 0 |

Most of the "slow update" was the session waiting for a redo log to become reusable. The run asserts at least one
checkpoint-incomplete wait and one alert-log line before the fix, and zero of both after. (Elapsed times vary from
run to run — 8 to 14 s on small logs in our runs — so the run checks the waits, not the clock.)

## Run it

```bash
./run.sh up       # start Oracle Database Free (first run pulls the image)
./run.sh all      # setup -> before -> fix -> after
```

```bash
./run.sh setup    # load CK.T (needs the default small logs: run on a fresh container)
./run.sh before   # the burst on 2 x 20 MB logs; assert the stall
./run.sh fix      # add 3 x 512 MB groups, switch onto them, drop the small ones
./run.sh after    # the same burst; assert no stall
./run.sh advise   # switches per minute + V$INSTANCE_RECOVERY.OPTIMAL_LOGFILE_SIZE
./run.sh sql      # SQL*Plus as SYSDBA
./run.sh destroy  # remove the container and its volume (use before re-running setup)
```

## Notes

- **You can't resize a redo log in place.** Add new, bigger groups, `ALTER SYSTEM SWITCH LOGFILE` until a new
  group is `CURRENT`, `ALTER SYSTEM CHECKPOINT`, wait for the old groups to show `INACTIVE` in `V$LOG`, then
  `ALTER DATABASE DROP LOGFILE GROUP n` and delete the old files at the operating-system level. Dropping a
  `CURRENT` or `ACTIVE` group fails. `scripts/fix.sql` does exactly this.
- **Spotting it.** The alert log line is the giveaway. From SQL: `V$SYSTEM_EVENT` for
  `log file switch (checkpoint incomplete)`, and log switches per minute from `V$LOG_HISTORY` (the lab saw 12 during
  one 14-second update). A common rule of thumb is a few switches per hour at peak, not per minute.
- **Oracle's own advice.** `V$INSTANCE_RECOVERY.OPTIMAL_LOGFILE_SIZE` suggests a size in MB, but only when
  `FAST_START_MTTR_TARGET` is set; with it at 0 the column is empty. With a 60-second target, it suggested 827 MB
  for this lab's workload.
- **Not the same as ORA-00257.** There the logs can't be reused because the *archiver* hasn't copied them; here
  because the *checkpoint* hasn't finished. Both freeze writers; the fixes are different.
- **Bigger logs mean longer crash recovery in theory** — more redo between checkpoints to replay. In practice
  incremental checkpointing and `FAST_START_MTTR_TARGET` bound recovery time independently of log size.
- Demo data is generic and invented. The lab runs in `NOARCHIVELOG` mode (the image default), which isolates the
  checkpoint effect from archiving.

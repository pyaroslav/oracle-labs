# Priority-txns lab — Oracle 26ai priority transactions: the database rolls back the blocker (ORA-63300)

Companion to [Oracle 26ai Priority Transactions: The Database Rolls Back the Blocker for You. Read the Fine
Print First.](https://uptimearchitect.com/blog/oracle-26ai-priority-transactions-ora-63300/)

A session holds a row lock and doesn't commit: a batch that paused, a SQL Developer window left open. Before 26ai,
everyone who wanted that row waited until a DBA found the session and killed it. Oracle AI Database 26ai can do it
for you: mark the less important work `LOW` (or `MEDIUM`), give the important work a wait target, and when a
`HIGH` transaction has waited that long, the database rolls the lower-priority blocker back. This lab proves what
that looks like for both sides, and the rules people get wrong: who can roll back whom, which waits count, what
the rolled-back session sees, and where the priority can't be set.

## What it proves

The blocker updates rows 1 and 500 of `APP.ORDERS` and then sits idle for 25 s without committing. The waiter
wants row 1. `PRIORITY_TXNS_HIGH_WAIT_TARGET = 10` unless stated otherwise.

| drill | case | asserted |
| --- | --- | --- |
| `off` | blocker `LOW`, waiter `HIGH`, wait targets at the default (2147483647 s) | nothing is rolled back; the waiter waits for the commit (~22 s) |
| `rollback` | the same, with the 10 s target | the waiter (event `enq: TX - row lock (HIGH priority)`) gets the row after 10 s; the idle blocker's **next** statement fails with `ORA-63302` + `ORA-63300`; every statement after it, `COMMIT` included, fails with `ORA-63302` until `ROLLBACK`; row 500 is back to `NEW` (the whole transaction is gone); one `terminated by transaction` line in the alert log; `txns rollback priority_txns_high_wait_target` +1 |
| `active` | the blocker is still running (PL/SQL sleeping after its update) | the running call is interrupted with `ORA-63300` at ~10 s and never reaches its second update |
| `rules` | `HIGH` vs `HIGH` (the default for every session), `LOW` vs `LOW` | no rollback |
| | `MEDIUM` blocker, `HIGH` waiter | rollback at the `HIGH` target |
| | `LOW` blocker, `MEDIUM` waiter | no rollback until `PRIORITY_TXNS_MEDIUM_WAIT_TARGET` is set; with 5 s, rollback at 5 s |
| `ddl` | the waiter is `ALTER TABLE ... ADD` | the `LOW` blocker is rolled back at 10 s and the column is added |
| | `TRUNCATE` | `ORA-00054` at once (it doesn't wait, so no wait target applies) |
| | `LOCK TABLE ... IN EXCLUSIVE MODE` | waits for the commit: a table-lock wait doesn't count, only row-lock waits |
| `track` | `PRIORITY_TXNS_MODE = TRACK` | nothing is rolled back; `txns track mode priority_txns_high_wait_target` +1 |
| `limits` | `ALTER SESSION SET txn_priority` inside an open transaction | `ORA-63304` |
| | the same inside a `DBMS_SCHEDULER` job | `ORA-63303`: scheduler jobs always run at `HIGH` |

## Run it

```bash
./run.sh up        # start Oracle Database Free (first run pulls the image)
./run.sh all       # every drill, each from setup, about 5 minutes
```

```bash
./run.sh setup     # reset: APP.ORDERS recreated, APP sessions killed, wait targets back to default, mode ROLLBACK
./run.sh off       # LOW on its own does nothing
./run.sh rollback  # the HIGH waiter rolls the LOW blocker back after 10 s; what each side sees
./run.sh active    # a running statement is interrupted too
./run.sh rules     # who can roll back whom
./run.sh ddl       # ADD COLUMN benefits, TRUNCATE and LOCK TABLE don't
./run.sh track     # TRACK mode counts instead of rolling back
./run.sh limits    # ORA-63304 and ORA-63303
./run.sh sql       # SQL*Plus as SYSDBA
./run.sh down      # stop and remove the container
./run.sh destroy   # remove the container and its volume
```

## Notes

- **Two settings, both needed.** `TXN_PRIORITY` (`HIGH` | `MEDIUM` | `LOW`, default `HIGH`) is a session setting.
  `PRIORITY_TXNS_HIGH_WAIT_TARGET` and `PRIORITY_TXNS_MEDIUM_WAIT_TARGET` are seconds, set with `ALTER SYSTEM`
  (PDB-modifiable), default 2147483647, which in practice means never. There is no `LOW` target: a `LOW` waiter
  never rolls anything back, and a `HIGH` transaction is never rolled back.
- **The 23ai names are still there.** `V$PARAMETER` on 26ai Free 23.26.3 also lists `txn_auto_rollback_mode`,
  `txn_auto_rollback_high_priority_wait_target` and `txn_auto_rollback_medium_priority_wait_target`, with the same
  values. The lab uses the 26ai names.
- **The idle blocker finds out late.** It isn't told when it is rolled back; its next call to the database fails.
  An application has to catch `ORA-63300` and `ORA-63302` and issue `ROLLBACK`, or every statement on that
  connection keeps failing with `ORA-63302`.
- **`setup` resets the parameters** in `FREEPDB1` (both targets back to 2147483647, mode `ROLLBACK`) and kills
  leftover `APP` sessions, so an interrupted drill doesn't leak into the next one.
- Measured on Oracle AI Database 26ai Free 23.26.3 (`gvenzl/oracle-free:latest`), 2026-11-25.

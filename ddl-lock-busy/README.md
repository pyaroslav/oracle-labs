# DDL-lock-busy lab — ORA-00054: resource busy, the session behind it, and the DDL that waits instead

Companion to [ORA-00054 Resource Busy: Find the Session, and Know Which DDL Will
Wait](https://uptimearchitect.com/blog/oracle-ora-00054-resource-busy-ddl/)

A deploy runs `TRUNCATE`, `CREATE INDEX` or `ALTER TABLE` and fails with `ORA-00054`. Somewhere, a session has an
uncommitted change to the same table: an application that forgot to commit, a SQL Developer window left open, a
pooled connection with an open transaction. This lab creates that session, shows what the 26ai message tells you
and what it doesn't, finds the session, and proves the parts that surprise people: some DDL doesn't fail at all,
it waits; `DDL_LOCK_TIMEOUT` makes every other writer wait too; and supplemental logging turns the waiting kind
back into `ORA-00054`.

## What it proves

The blocker is a session that updates one row of `APP.ORDERS` and sits idle without committing.

| drill | case | asserted |
| --- | --- | --- |
| `busy` | `TRUNCATE` | `ORA-00054` at once; the number in the 26ai message is `ORDERS`' `OBJECT_ID`; no session is named |
| `find` | `V$LOCKED_OBJECT` for that object | exactly the blocker's SID, in mode 3; `INACTIVE`; an open transaction; `BLOCKING_SESSION` empty everywhere |
| `kinds` | `CREATE INDEX`, `DDL_LOCK_TIMEOUT = 5` | `ORA-00054` after 5 s |
| | `ALTER TABLE ... ADD`, same timeout | no error: waits until the blocker commits (~28 s), with the blocker in `BLOCKING_SESSION`; another session's `UPDATE` runs at once |
| | `CREATE INDEX ... ONLINE`, same timeout | the same |
| `queue` | `DROP COLUMN`, `DDL_LOCK_TIMEOUT = 30`, blocker holds 45 s | another session's `UPDATE` of a **different** row waits behind the DDL (~27 s; `BLOCKING_SESSION` = the DDL, `FINAL_BLOCKING_SESSION` = the blocker); the DDL still ends in `ORA-00054` |
| `suplog` | `ALTER DATABASE ADD SUPPLEMENTAL LOG DATA`, then `ADD` | `ORA-00054` at once; `CREATE INDEX ... ONLINE` still waits |
| `fix` | `ALTER SYSTEM KILL SESSION` on the blocker | the `TRUNCATE` runs; the blocker's uncommitted change is rolled back |

## Run it

```bash
./run.sh up        # start Oracle Database Free (first run pulls the image)
./run.sh all       # busy -> find -> kinds -> queue -> suplog -> fix (each starts from setup), about 5 minutes
```

```bash
./run.sh setup     # reset: APP.ORDERS recreated, leftover APP sessions killed, supplemental logging off
./run.sh busy      # ORA-00054, and what the message tells you
./run.sh find      # find the session from the message
./run.sh kinds     # DDL that gives up vs DDL that waits
./run.sh queue     # DDL_LOCK_TIMEOUT makes everyone else's writes wait
./run.sh suplog    # supplemental logging turns ADD COLUMN back into ORA-00054
./run.sh fix       # end the idle session; the DDL runs
./run.sh sql       # SQL*Plus as SYSDBA
./run.sh down      # stop and remove the container
./run.sh destroy   # remove the container and its volume
```

## Notes

- **Two kinds of DDL.** Oracle calls them blocking and nonblocking. Both wait for transactions already open on the
  table. Blocking DDL also makes new DML wait behind it, and gives up with `ORA-00054` when `DDL_LOCK_TIMEOUT`
  runs out (at once, with the default of 0). Nonblocking DDL lets new DML through and ignores `DDL_LOCK_TIMEOUT`:
  it waits as long as the transaction stays open. The list of nonblocking DDL is in the SQL Language Reference
  ("List of Nonblocking DDLs"); plain `ALTER TABLE ... ADD` joined it in 23.3.
- **The 26ai message names the object, not the session.** "The resource being locked can be identified by
  73205 ("Table")" is the table's `OBJECT_ID`. Older releases say only "resource busy and acquire with NOWAIT
  specified or timeout expired".
- **`BLOCKING_SESSION` only helps when something is waiting.** A DDL that failed at once isn't waiting, so nothing
  points at the blocker. `V$LOCKED_OBJECT` does.
- **Supplemental logging is database-wide.** The `suplog` drill turns it on in the CDB root and off again; `setup`
  also turns it off, so an interrupted run doesn't leave it on.
- **`setup` kills leftover `APP` sessions** from earlier drills, so each drill starts with one blocker.

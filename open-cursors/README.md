# Open-cursors lab — ORA-01000: maximum open cursors exceeded

Companion to [ORA-01000 Maximum Open Cursors Exceeded: Don't Raise the Limit, Find the
Leak](https://uptimearchitect.com/blog/oracle-ora-01000-maximum-open-cursors/)

`OPEN_CURSORS` limits how many cursors **one session** can have open at once. An application that opens a cursor and
never closes it (a `ResultSet` or `Statement` that's never closed, a ref cursor returned by a procedure and forgotten)
leaks one per call, and each pooled connection fails with ORA-01000 when its leak reaches the limit. This lab leaks
cursors on purpose, finds the leaking session and statement, shows the query that blames a healthy session, and tests
what raising `OPEN_CURSORS` really does.

The "application" is SQL*Plus calling `APP.GET_ORDERS`, a procedure that returns a result set (`SYS_REFCURSOR`), and
holding each result set in its own `REFCURSOR` variable without closing it. On the server that is the same thing as
a JDBC `ResultSet` that's never closed. No client runtime needed beyond the image.

## What it proves

| step | what you see | asserted |
| --- | --- | --- |
| **Leak** (`OPEN_CURSORS` 300) | ORA-01000 from call **299** (the session already had 2 cursors open); the first error, and only the first, says `Potential Leaked SQL_ID: 4cgc7syjwjw3y` (26ai); nothing in the alert log | all of it |
| **Blame** | 298 leaked, then a different procedure: that call fails, and the message names the **leaked** statement. Another session runs the same call at the same moment without error | both |
| **Find** | a leaking session and a busy healthy one (`SESSION_CACHED_CURSORS` 1000): by raw `V$OPEN_CURSOR` row count the healthy one has more (458, over the limit) while its `opened cursors current` is 2. Filtering `CURSOR_TYPE LIKE 'OPEN%'` finds one statement open 250 times | all of it |
| **Raise** (`OPEN_CURSORS` 300 → 400 in the PDB) | the stuck session keeps failing (55 of 55); a session connected **before** the raise still fails at call 299; a new session fails at call **399** | all three |
| **Fix** | the same calls, each result set read and closed: 400 calls, no ORA-01000 | yes |

## Run it

```bash
./run.sh up        # start Oracle Database Free (first run pulls the image)
./run.sh all       # leak -> blame -> find -> raise -> fix, about 30 seconds
```

```bash
./run.sh setup     # schema APP: ORDERS, GET_ORDERS and GET_CUSTOMER (ref cursors); resets the lab
./run.sh leak      # never close the result set; ORA-01000 at the limit
./run.sh blame     # an unrelated call fails; the message names the leaker
./run.sh find      # find the leaking session and statement (and the false positive)
./run.sh raise     # raise OPEN_CURSORS: existing sessions keep the old limit, new ones fail later
./run.sh fix       # close every result set: no error
./run.sh sql       # SQL*Plus as SYSDBA
./run.sh destroy   # remove the container and its volume
```

Each step starts from `setup`, so they can run in any order.

## Notes

- **The limit:** this image runs with `OPEN_CURSORS` 300. The parameter's documented default is 50. `setup` sets it
  back to 300 in the PDB, so a `raise` run that stopped halfway doesn't leak into the next run.
- **The SQL_ID in the message** is new in the 26ai error text; the lab doesn't test other releases. It appears on the
  first ORA-01000 of a session only. When the failing statement needs recursive SQL first, the error arrives as
  `ORA-00604` with ORA-01000 underneath; the lab saw both forms.
- **Raising the limit** was tested with `ALTER SYSTEM` in the PDB on 26ai. Sessions already connected kept the old
  limit, whether they were stuck or not. Recycle the application's connections after a change.
- **Cached cursors:** `V$OPEN_CURSOR` lists closed cursors in the session cursor cache (`SESSION CURSOR CACHED` and
  others), which don't count toward the limit. A statement must be parsed a few times before it's cached, so the
  busy session runs 450 statements four times each. Use the `opened cursors current` statistic or
  `CURSOR_TYPE LIKE 'OPEN%'`.
- **Background sessions** use SQL*Plus `prompt` and `host sleep` as markers and pauses: a session at the limit can't
  run even `SELECT ... FROM dual` or a PL/SQL call.

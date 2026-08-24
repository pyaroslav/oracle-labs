# Flashback lab — undo human error at three scales, and watch each one work

Companion to [Oracle Flashback: Undo at the Database
Level](https://uptimearchitect.com/blog/oracle-flashback-undo-at-the-database-level/).

Most "recovery" stories are really *restore* stories — go find last night's backup, hope it's good, lose
everything since. Flashback is the other kind: fast, surgical, point-in-time undo built into the database.
This lab makes three human-error disasters and reverses each with the right Flashback tool, hardest-hitting
first — a bad UPDATE, a dropped table, and a dropped *schema* that takes the whole database down with it. No
Oracle client needed; everything runs in the container.

## What it proves

| Disaster | Recovery | Asserted result |
| --- | --- | --- |
| A committed `UPDATE` with no `WHERE` zeroes **1000** balances | `FLASHBACK TABLE ... TO SCN` | 1000 zeroed → **0** still zero after flashback |
| The table is **dropped** outright | `FLASHBACK TABLE ... TO BEFORE DROP` | gone after drop → back with **1000** rows |
| The whole app schema is **dropped** (`DROP USER ... CASCADE`) | `FLASHBACK DATABASE TO RESTORE POINT` | schema gone → back with **1000** rows |

Each drill captures its own before/after and **asserts** the recovery worked — if a flashback doesn't restore
the data, the run fails. It's a test, not a claim. The third drill is the real one: it enables `ARCHIVELOG`,
creates a **guaranteed restore point**, drops the entire `LABUSER` schema, then shuts the database to a mount,
`FLASHBACK DATABASE`, and `OPEN RESETLOGS` — rewinding the *entire* database, not just one object.

> **Why `ROW MOVEMENT` matters.** `FLASHBACK TABLE ... TO SCN` physically re-inserts the recovered rows,
> which changes their rowids — so the table must be created with `ENABLE ROW MOVEMENT` or the flashback fails.
> The lab sets it; it's the single most common reason a table-level flashback is refused.

## Run it

```bash
./run.sh up      # start the database (first run pulls the image)
./run.sh all     # setup -> badupdate -> drop -> database (each asserted)
```

Or step through it:

```bash
./run.sh setup     # enable ARCHIVELOG + FRA (one restart), build the demo schema (row movement on)
./run.sh badupdate # reverse a WHERE-less UPDATE with FLASHBACK TABLE ... TO SCN
./run.sh drop      # recover a dropped table with FLASHBACK TABLE ... TO BEFORE DROP
./run.sh database  # rewind the whole database with FLASHBACK DATABASE TO RESTORE POINT
./run.sh sql       # SQL*Plus as SYSDBA -- poke at it yourself
```

## What you should see

```
>> DRILL 1 — reverse a bad UPDATE with FLASHBACK TABLE ... TO SCN
   balances zeroed by the bad UPDATE: 1000   still zero after flashback: 0   rows: 1000
   -> the table was rewound to the moment before the mistake.

>> DRILL 2 — recover a dropped table with FLASHBACK TABLE ... TO BEFORE DROP
   table present after drop: 0   after flashback: 1   rows: 1000
   -> the dropped table came back from the recycle bin, rows intact.

>> DRILL 3 — rewind the WHOLE database with FLASHBACK DATABASE TO RESTORE POINT
   after the disaster: LABUSER schema exists? no (count 0)
   ... Flashback complete.
   after FLASHBACK DATABASE: labuser.accounts rows = 1000
   -> the dropped schema is back — the entire database was rewound to before the disaster.

>> PASS: bad UPDATE reversed (TO SCN), dropped table recovered (TO BEFORE DROP), whole database rewound (TO RESTORE POINT).
```

## Try it yourself

Once it's up, `./run.sh sql` and watch a Flashback Query show you the past directly:

```sql
ALTER SESSION SET CONTAINER = FREEPDB1;

-- what did the table look like 5 minutes ago? (Flashback Query)
SELECT COUNT(*) FROM labuser.accounts AS OF TIMESTAMP SYSTIMESTAMP - INTERVAL '5' MINUTE;

-- the recycle bin (what FLASHBACK TABLE ... TO BEFORE DROP reads from)
SELECT object_name, original_name, droptime FROM recyclebin;

-- guaranteed restore points and how much flashback space they pin
SELECT name, scn, guarantee_flashback_database, storage_size FROM v$restore_point;
```

## Notes

- **One restart in `setup`.** `ARCHIVELOG` is required for the whole-database flashback (drill 3), so `setup`
  enables it and configures the FRA once; everything after is online.
- **The young-object limit (ORA-01466).** Oracle refuses a flashback to within ~seconds of a table's
  creation, so `run.sh` waits for the demo table to age past the limit before the table-level drills.
- **`OPEN RESETLOGS`** (drill 3) starts a new redo stream — expected after a `FLASHBACK DATABASE`. The lab
  drops the guaranteed restore point afterward so it stops pinning flashback logs in the FRA.
- Demo data is generic and invented (`Holder 0001` … with random balances) — nothing sensitive.

## Cleanup

```bash
./run.sh down     # stop the container, keep the data volume
./run.sh destroy  # remove everything including the volume
```

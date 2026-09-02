# Data Pump lab — export it, drop it, prove it came back

Companion to [Oracle Data Pump, Done Right: A Migration You Can
Prove](https://uptimearchitect.com/blog/oracle-data-pump-done-right/).

"The migration worked" is easy to say and rarely checked. This lab checks it the only way that settles the
argument: it builds a schema of **known size** (5,000 customers, 20,000 orders), exports it with `expdp`, then
asserts the row counts survive three operations — a round trip, a schema remap, and a filtered export. No Oracle
client needed; `expdp`, `impdp`, and SQL\*Plus all run inside the container via `docker exec`.

## What it proves

| Drill | Operation | Asserted result |
| --- | --- | --- |
| `export` | `expdp SCHEMAS=dpshop` | job completes, `shop.dmp` exists |
| `roundtrip` | drop `DPSHOP`, `impdp` it back | `DPSHOP` = **5,000 + 20,000** rows (lossless) |
| `remap` | `impdp REMAP_SCHEMA=dpshop:dpclone` | `DPCLONE` = **5,000 + 20,000** rows (new schema) |
| `filter` | `expdp INCLUDE=TABLE:"IN ('ORDERS')"` → `impdp` into `DPONLY` | `DPONLY` has **only ORDERS** (20,000), no CUSTOMERS |

The run **asserts** every number and fails if a round trip drops a row, a remap lands the wrong counts, or the
`INCLUDE` filter leaks a table. It's a test, not a claim.

## Run it

```bash
./run.sh up      # start the database (first run pulls the image)
./run.sh all     # setup -> export -> roundtrip -> remap -> filter
```

Or step through it:

```bash
./run.sh setup      # build DPSHOP (5,000 customers, 20,000 orders) + the Data Pump DIRECTORY
./run.sh export     # expdp the schema to shop.dmp
./run.sh roundtrip  # drop DPSHOP, impdp it back, assert the row counts match
./run.sh remap      # impdp REMAP_SCHEMA=dpshop:dpclone, assert the counts in the new schema
./run.sh filter     # expdp only ORDERS (via a parfile), impdp into DPONLY, assert it filtered exactly
./run.sh sql        # SQL*Plus as SYSDBA
```

## What you should see

```
   after re-import: DPSHOP customers=5000  orders=20000
   -> lossless round trip: exact same 5,000 + 20,000 rows came back.
   DPCLONE customers=5000  orders=20000
   -> same data, new schema name. That's the migration move.
   DPONLY tables=[ORDERS]  orders=20000
   -> only ORDERS came across (no CUSTOMERS). INCLUDE filtered the export exactly.
```

## Try it yourself

`./run.sh sql`, then look at the DIRECTORY and dump files, or run an export by hand:

```sql
ALTER SESSION SET CONTAINER = FREEPDB1;
SELECT directory_name, directory_path FROM dba_directories WHERE directory_name = 'DP_DIR';
```

```bash
# from the host, list the dumps Data Pump wrote inside the container:
docker exec ora-data-pump-lab ls -la /opt/oracle/dpdump
```

## Notes

- **Data Pump is server-side.** `expdp`/`impdp` write and read through the `DP_DIR` DIRECTORY object
  (`/opt/oracle/dpdump` in the container), not a client path. That's the fundamental difference from legacy
  `exp`/`imp`.
- **Filters go in a parfile.** The `filter` drill uses a PARFILE for `INCLUDE=TABLE:"IN ('ORDERS')"` — passing
  that on the command line gets its quotes mangled by the shell. The lab writes `filt.par` into the container
  and runs `expdp parfile=…`.
- **A TABLE-mode filtered dump has no CREATE USER DDL**, so the `filter` drill pre-creates `DPONLY` before the
  remap import (otherwise `impdp` fails with `ORA-01918: user does not exist`).
- **Data Pump needs no extra license** and is in every edition, including Oracle Database Free.
- Demo data is generic and invented — nothing sensitive.

## Cleanup

```bash
./run.sh down     # stop the container, keep the data volume
./run.sh destroy  # remove everything including the volume
```

# VPD lab — row-level security you can't route around

Companion to [Oracle Virtual Private Database: Row-Level Security You Can't Route
Around](https://uptimearchitect.com/blog/oracle-vpd-row-level-security/).

Everyone "knows" you can hide rows with a view. The problem is a view is a *detour* — grant someone the base
table (a report, an export, an ad-hoc query) and the detour is gone. **Virtual Private Database** (VPD, via
`DBMS_RLS`) does it at the base table instead: a policy function returns a `WHERE` predicate that Oracle
**transparently appends to every query**, per session. There is nothing to route around.

This lab builds one `ORDERS` table of **known shape** — 3,000 rows split **1,800 EAST / 1,200 WEST** — puts a
VPD policy on it, then reads it back as three users and **asserts** what each one is allowed to see.

## What it proves

| Reader | What VPD does | Asserted result |
| --- | --- | --- |
| `REP_EAST` | predicate `region = 'EAST'` appended | sees **1,800** rows, region **EAST** only, `SUM` = **180000**, and a lookup of WEST `id=3` returns **0** |
| `REP_WEST` | predicate `region = 'WEST'` appended | sees **1,200** rows, region **WEST** only, `SUM` = **120000** |
| `MGR` | holds **`EXEMPT ACCESS POLICY`** | sees all **3,000** rows, both regions, `SUM` = **300000** |

The predicate is checked on `COUNT`, on `SUM(amount)`, **and** on a targeted `WHERE id = 3` — so the filter
holds for aggregates and by-id lookups alike, not just a naive row listing. That's the whole difference from a
view: **it's enforced on the base table for every statement.** If a rep ever sees another region's row, or the
aggregates aren't filtered, the run fails.

This is the **row-level** counterpart to the [Data Redaction
lab](../data-redaction/): redaction masks a column's *value* but leaves the row; VPD removes the *row*. And
`EXEMPT ACCESS POLICY` here is the exact analog of `EXEMPT REDACTION POLICY` there.

## Run it

```bash
./run.sh up      # start the database (first run pulls the image)
./run.sh all     # setup -> prove
```

Or step through it:

```bash
./run.sh setup   # build ORDERS (1,800 EAST / 1,200 WEST) + the VPD policy + REP_EAST / REP_WEST / MGR
./run.sh prove   # read as each user; assert each sees only what it should
./run.sh sql     # SQL*Plus as SYSDBA (SYS is exempt from VPD, so it sees the whole table)
./run.sh east    # SQL*Plus as REP_EAST — run your own queries and watch them come back EAST-only
```

## What you should see

```
   user      rows   regions    sum(amt)   sees WEST id=3?
   ----      ----   -------    --------   ---------------
   REP_EAST  1800   EAST       180000     0
   REP_WEST  1200   WEST       120000     1
   MGR       3000   EAST,WEST  300000     (exempt)
   -> each rep is confined to its region on rows, sum, AND a by-id lookup; MGR is exempt and sees all 3,000.
```

## Try it yourself

`./run.sh east`, then try to escape your region — you can't:

```sql
SELECT COUNT(*) FROM vpdown.orders;                         -- 1800, not 3000
SELECT COUNT(*) FROM vpdown.orders WHERE region = 'WEST';   -- 0  (the predicate wins)
SELECT COUNT(*) FROM vpdown.orders WHERE id = 3;            -- 0  (id 3 is a WEST row)
SELECT SUM(amount) FROM vpdown.orders;                      -- 180000, your region only
```

## Notes

- **The policy function keys off the session user** (`SYS_CONTEXT('USERENV','SESSION_USER')`) — an
  unspoofable session fact. A common production variant maps the user to a region through an **application
  context** set at logon, which is what you want when app servers share pooled connections.
- **`EXEMPT ACCESS POLICY`** exempts a user from *every* VPD policy in the database (like `SYS`). Grant it to
  as few accounts as possible and audit who holds it — it is the master key to every row policy you've set.
- **VPD applies to the statement types you name** — this lab policy covers `SELECT`. Real policies often add
  `INSERT`/`UPDATE`/`DELETE` (with `update_check`) so a user can't insert or move a row outside their slice.
- **VPD is a base-table control, not a view.** Grant the table and the policy still applies; there is no
  detour. That's the point.
- Demo data is generic and invented — nothing sensitive.

## Cleanup

```bash
./run.sh down     # stop the container, keep the data volume
./run.sh destroy  # remove everything including the volume
```

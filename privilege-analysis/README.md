# Privilege Analysis lab — what they were granted vs what they used

Companion to [Oracle Privilege Analysis: You Granted DBA. Here's What They Actually
Used](https://uptimearchitect.com/blog/oracle-privilege-analysis/).

Every real database accretes privilege. Someone needs one table read, the ticket says "just give it the app
role," and three years later that account can `DROP ANY TABLE` and nobody remembers why. **Privilege Analysis**
(`DBMS_PRIVILEGE_CAPTURE`) settles it with evidence: it records the privileges a session *actually exercises*,
so you compare **used** against **granted** and revoke the difference — least privilege from data, not a guess.

This lab builds a deliberately over-privileged user, captures a tiny real workload, and **asserts** the gap.

## What it proves

`APPUSER` is granted the role `PA_ROLE`, which carries **12 privileges** — ten system privileges (including
`SELECT ANY TABLE`, `DROP ANY TABLE`, `CREATE ANY TABLE`, `ALTER ANY TABLE`) plus `SELECT` on two tables. Then
the workload does three small things: log in, read `PAOWN.CUSTOMERS` (a table it has an explicit grant on), and
create one table in its own schema.

| | Privileges |
| --- | --- |
| **USED** | `CREATE SESSION`, `CREATE TABLE`, `SELECT` on `PAOWN.CUSTOMERS` |
| **UNUSED** | `SELECT ANY TABLE`, `DROP ANY TABLE`, `CREATE ANY TABLE`, `ALTER ANY TABLE`, `CREATE VIEW`, `CREATE PROCEDURE`, `CREATE SEQUENCE`, `CREATE SYNONYM`, `SELECT` on `PAOWN.ORDERS` |

The headline is `SELECT ANY TABLE` landing in **unused**: the workload read one table it was explicitly granted,
so the god-mode "read anything" privilege was never exercised — exactly the kind of grant least privilege says to
pull. The run **asserts** the used set contains the three it exercised, the unused set contains the scary `ANY`
privileges, and that there are more unused than used. If the capture stops distinguishing them, the run fails.

## Run it

```bash
./run.sh up      # start the database (first run pulls the image)
./run.sh all     # setup -> workload -> analyze
```

Or step through it:

```bash
./run.sh setup     # build the over-privileged APPUSER (role PA_ROLE) + start the capture
./run.sh workload  # run the tiny real workload AS APPUSER (this is what gets captured)
./run.sh analyze   # stop the capture, generate the result, report USED vs UNUSED
./run.sh appuser   # SQL*Plus as APPUSER — poke around and add to what gets captured
```

## What you should see

```
   USED   (4): sys=[CREATE_SESSION,CREATE_TABLE]  obj=[CUSTOMERS]
   UNUSED (9): sys=[ALTER_ANY_TABLE,CREATE_ANY_TABLE,CREATE_PROCEDURE,CREATE_SEQUENCE,CREATE_SYNONYM,CREATE_VIEW,DROP_ANY_TABLE,SELECT_ANY_TABLE]  obj=[ORDERS]
   -> APPUSER used 4 of 13 privileges; 9 sat unused, incl. SELECT/DROP/CREATE ANY TABLE.
```

## Notes

- **The capture must be enabled *before* the workload runs.** `setup` creates and enables a `G_CONTEXT` capture
  scoped to `APPUSER` (`SYS_CONTEXT('USERENV','SESSION_USER') = 'APPUSER'`); `analyze` disables it and calls
  `DBMS_PRIVILEGE_CAPTURE.GENERATE_RESULT`, which is what populates the `DBA_USED_PRIVS` / `DBA_UNUSED_PRIVS`
  (and the `*_SYSPRIVS` / `*_OBJPRIVS`) views.
- **`SELECT ANY TABLE` shows as unused on purpose.** When a session has both an object grant and a system `ANY`
  privilege, Oracle authorizes with the object grant, so the `ANY` privilege is correctly recorded as unused —
  the single most common real over-grant.
- **Privilege Analysis is included in Enterprise Edition** (since 18c it no longer needs the Database Vault
  option) and is available in Oracle Database Free, which is why this runs with nothing but Docker.
- **Capture types:** `G_DATABASE` (everything), `G_ROLE` (privileges from named roles), `G_CONTEXT` (a condition,
  used here), and `G_ROLE_AND_CONTEXT`. Only one `G_DATABASE` capture runs at a time; context/role captures
  coexist with the always-on `ORA$DEPENDENCY`.
- Demo data is generic and invented — nothing sensitive.

## Cleanup

```bash
./run.sh down     # stop the container, keep the data volume
./run.sh destroy  # remove everything including the volume
```

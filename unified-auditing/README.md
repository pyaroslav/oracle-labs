# Unified-auditing lab — prove your policies actually capture

Companion to [Oracle Unified Auditing Without the
Noise](https://uptimearchitect.com/blog/oracle-unified-auditing/).

"We have auditing" and "we checked that our auditing works" are different sentences. This lab makes the
second one true: it enables the baseline policies plus one custom policy, **triggers three real audited
events**, flushes the queued audit buffer, and queries `UNIFIED_AUDIT_TRAIL` to prove each one was
recorded. If a policy silently isn't capturing, the run fails. No Oracle client needed — everything runs
in the container.

The image is Oracle Database Free (currently 26ai), where traditional auditing is desupported — so this
is unified auditing on its own, exactly the world you land in on 23ai.

## What it proves

| Triggered action | Policy that should catch it |
| --- | --- |
| A **failed login** (wrong password) | `ORA_LOGON_FAILURES` (pre-enabled baseline) |
| A **`CREATE USER`** | `ORA_SECURECONFIG` (pre-enabled baseline) |
| A **read of a sensitive table** (`hr.employee_salary`) | `aud_salary_access` (a custom policy the lab creates) |

The verify step calls `DBMS_AUDIT_MGMT.FLUSH_UNIFIED_AUDIT_TRAIL` first — unified records are written in
queued (async) mode, so the newest ones sit in an SGA buffer until you flush them. That flush is the
lab's most useful takeaway: *"nothing in the trail" during an investigation often just means you didn't
flush.*

## Run it

```bash
./run.sh up      # start the database (first run pulls the image)
./run.sh all     # setup -> trigger -> verify -> summary
```

Or step by step:

```bash
./run.sh setup    # sensitive table, an auditee user, baseline + custom policy
./run.sh trigger  # do the three audited actions
./run.sh verify   # flush the buffer, then prove each landed in the trail
./run.sh sql      # SQL*Plus as SYSDBA — poke at UNIFIED_AUDIT_TRAIL yourself
```

## What you should see

```
>> VERIFY: flushing the audit buffer, then reading UNIFIED_AUDIT_TRAIL...
  --------------------------------------------------------------------
  failed login  (ORA_LOGON_FAILURES)         CAPTURED  (1 record/s)
  CREATE USER   (ORA_SECURECONFIG)           CAPTURED  (3 record/s)
  sensitive read (aud_salary_access policy)  CAPTURED  (1 record/s)
  --------------------------------------------------------------------
  3 events triggered, 3 captured.

>> PASS: every triggered action was recorded in the unified audit trail.
```

The run **fails loudly** if any triggered event isn't in the trail — that's the whole point: a policy you
enabled but that isn't actually capturing is worse than none, and this tells you which one. The CI matrix
runs the full cycle on every push.

## Try it yourself

Once it's up, `./run.sh sql` and read the trail the way a real investigation would:

```sql
ALTER SESSION SET CONTAINER = FREEPDB1;
EXEC DBMS_AUDIT_MGMT.FLUSH_UNIFIED_AUDIT_TRAIL;

SELECT event_timestamp, dbusername, action_name, object_name, return_code, unified_audit_policies
FROM   unified_audit_trail
WHERE  unified_audit_policies IS NOT NULL
ORDER  BY event_timestamp DESC FETCH FIRST 20 ROWS ONLY;
```

## Cleanup

```bash
./run.sh down     # stop the container, keep the data volume
./run.sh destroy  # remove everything including the volume
```

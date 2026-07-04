# Scenario 01 — "The version already says 19.27, so we're patched"

A colleague applied the **19.27** Release Update to a single-instance **19c** database last night,
restarted it, and closed the change ticket. This morning the app team reports the database is behaving
oddly after the patch. You check three things.

**The binary home:**
```console
$ $ORACLE_HOME/OPatch/opatch lspatches
37641958;Database Release Update : 19.27.0.0.250415 (37641958)
37642901;OCW Release Update : 19.27.0.0.250415 (37642901)

OPatch succeeded.
```

**The instance version:**
```sql
SQL> select version_full from v$instance;

VERSION_FULL
-----------------
19.27.0.0.0
```

**The SQL-patch registry:**
```sql
SQL> select patch_id, action, status, description
  2  from dba_registry_sqlpatch order by action_time;

  PATCH_ID ACTION   STATUS   DESCRIPTION
---------- -------- -------- ----------------------------------------------
  36912597 APPLY    SUCCESS  Database Release Update : 19.26.0.0.250121
```

The home is on 19.27. `version_full` says 19.27. But the SQL-patch registry's newest row is **19.26**.

---

**Your call: what happened, and what do you do?**

# Scenario 03 — "Patching is clean — the registry is consistent"

It's **2026**. During a security audit you inspect a **19c** database that the team insists is
"patched and healthy." Everything is internally consistent:

```sql
SQL> select version_full from v$instance;

VERSION_FULL
-----------------
19.18.0.0.0
```

```console
$ $ORACLE_HOME/OPatch/opatch lspatches
34765931;Database Release Update : 19.18.0.0.230117 (34765931)
34762026;OCW Release Update : 19.18.0.0.230117 (34762026)

OPatch succeeded.
```

```sql
SQL> select patch_id, action, status, description
  2  from dba_registry_sqlpatch order by action_time;

  PATCH_ID ACTION   STATUS   DESCRIPTION
---------- -------- -------- ----------------------------------------------
  34765931 APPLY    SUCCESS  Database Release Update : 19.18.0.0.230117
```

The binaries, the version, and the SQL registry **all agree** on 19.18. No `datapatch` gap, no errors.
The team says: "See? Fully patched."

---

**Your call: is this database adequately patched — and if not, why not?**

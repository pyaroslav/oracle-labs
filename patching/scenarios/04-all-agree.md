# Scenario 04 — The quarterly patch just landed

You applied the **19.27** Release Update your team qualified this cycle to a single-instance **19c**
database this morning — out-of-place (new home), then `datapatch`. Before you hand it back, you verify.
(This one is about whether the patch is *correctly applied* — not whether 19.27 is the newest RU going;
that's scenario 03.)

```console
$ $ORACLE_HOME/OPatch/opatch lspatches
37641958;Database Release Update : 19.27.0.0.250415 (37641958)
37642901;OCW Release Update : 19.27.0.0.250415 (37642901)

OPatch succeeded.
```

```sql
SQL> select version_full from v$instance;

VERSION_FULL
-----------------
19.27.0.0.0
```

```sql
SQL> select patch_id, action, status, description
  2  from dba_registry_sqlpatch order by action_time;

  PATCH_ID ACTION   STATUS   DESCRIPTION
---------- -------- -------- ----------------------------------------------
  36912597 APPLY    SUCCESS  Database Release Update : 19.26.0.0.250121
  37641958 APPLY    SUCCESS  Database Release Update : 19.27.0.0.250415
```

---

**Your call: what action, if any, is required before you close the change?**

# Scenario 06 — "datapatch ran, so we're good"

A **19c** database was patched to RU **19.27**: OPatch on the home, then `datapatch`. The `datapatch`
command completed and returned you to the prompt, and the operator marked the step done. You verify the
registry before signing off.

```console
$ $ORACLE_HOME/OPatch/opatch lspatches
37641958;Database Release Update : 19.27.0.0.250415 (37641958)

OPatch succeeded.
```

```sql
SQL> select patch_id, action, status, description
  2  from dba_registry_sqlpatch order by action_time;

  PATCH_ID ACTION   STATUS       DESCRIPTION
---------- -------- ------------ ------------------------------------------
  36912597 APPLY    SUCCESS      Database Release Update : 19.26.0.0.250121
  37641958 APPLY    WITH ERRORS  Database Release Update : 19.27.0.0.250415
```

The binaries are on 19.27 and there *is* a 19.27 row in the registry — the step "ran." But look at the
`STATUS` column.

---

**Your call: is this database correctly patched, and what do you do?**

# Migration ORA-00942 lab — which reads break after a schema-mode Data Pump import, and how to carry over what it leaves behind

Companion to [ORA-00942 After a Data Pump Migration: The Table Is There. The Grant
Isn't.](https://uptimearchitect.com/blog/oracle-ora-00942-after-migration/)

The import finished with one error, maybe none. Row counts match. Then a reporting tool, a web app and an analyst
log in to the new database and some of them get `ORA-00942: table or view does not exist` on tables that are
plainly there. This lab builds a small source with three readers, each reaching the application tables a
different way (a direct grant, a public synonym, a role), migrates the schemas with a schema-mode export, and shows
which reads survive, which don't, and why. Then it lists the gaps on the source before the export and closes them on
the target with Data Pump.

## What it proves

The source is `FREEPDB1`. `REF` owns `CURRENCIES`; `APP` owns `ORDERS`, `CUSTOMERS` and a view over
`REF.CURRENCIES`. The lab creates a second PDB, `TARGET`, as the new database, and imports
`expdp SCHEMAS=REF,APP` into it.

| drill | case | asserted |
| --- | --- | --- |
| `import` | reader accounts created on the target first, then one `impdp SCHEMAS=REF,APP` | the job reports **1** error (the grant to role `APP_READ`) and nothing about the public synonym |
| | `REPORTING`: `select ... from app.orders` (direct grant) | works: grants made by `APP` on its own objects travel with the schema |
| | `WEBAPP`: `select ... from orders` (public synonym) | `ORA-00942: table or view "WEBAPP"."ORDERS" does not exist`: public synonyms are not in a schema export |
| | `ANALYST`: `select ... from app.customers` (role `APP_READ`) | `ORA-00942: table or view "APP"."CUSTOMERS" does not exist`: the role is not in a schema export, so the grant to it failed |
| | `APP`: its view over `REF.CURRENCIES` | works (same job, so the grant from `REF` to `APP` was applied) |
| `order` | `REF` and `APP` as two separate jobs, `REF` first, no reader accounts yet | **4** failed grants (to `APP`, `APP_READ`, `REPORTING`, `WEBAPP`); `APP` gets `ORA-00942` on `REF.CURRENCIES` and `ORA-04063` on its own view |
| | reader accounts created after the import | `REPORTING` still gets `ORA-00942`: the grant never ran |
| | `impdp ... INCLUDE=OBJECT_GRANT` re-run | `REPORTING` reads; the view is `VALID` again on its next use, no manual recompile |
| `message` | what the 26ai message names | the object it resolved to: an unqualified name with no synonym shows the user's own schema (`"WEBAPP"."NO_SUCH_TABLE"`); a missing grant and a missing table give the same message |
| `preflight` | source queries, before the export | 1 role, 1 role member, 1 public synonym, 2 user grantees that must exist first, 1 grant between the migrated schemas |
| `fix` | full-mode, metadata-only export filtered to the roles and public synonyms that point at `REF` and `APP`; the role membership granted; `INCLUDE=OBJECT_GRANT` re-run | all four reads work |
| `plsql` | `ANALYST`'s same `SELECT` inside a procedure | `ORA-00942` at compile time, on the target **and on the source**: definer's-rights PL/SQL doesn't use roles. A direct grant makes it `VALID` |

## Run it

```bash
./run.sh up         # start Oracle Database Free (first run pulls the image)
./run.sh all        # setup -> import -> message -> preflight -> fix -> plsql -> setup -> order, about 2 minutes
```

```bash
./run.sh setup      # build the source, export REF and APP, recreate an empty TARGET (safe to rerun)
./run.sh import     # schema-mode import: which reads break, and what the job log says
./run.sh order      # separate jobs in the wrong order, before the readers exist
./run.sh message    # what the 26ai ORA-00942 message names
./run.sh preflight  # the source queries that list what schema mode leaves behind
./run.sh fix        # carry over roles, public synonyms and grants (run after import)
./run.sh plsql      # works in SQL, ORA-00942 in a procedure (run after fix)
./run.sh sql        # SQL*Plus as SYSDBA
./run.sh down       # stop and remove the container
./run.sh destroy    # remove the container and its volume
```

## Notes

- **The source and the target are two PDBs in one container.** `setup` drops and recreates `TARGET` from the seed
  (a few seconds), so every drill starts from an empty new database. Data Pump reads and writes one directory,
  `/opt/oracle/oradata/mig`, from both.
- **A schema export carries what the schema owns.** Its tables, views, code, its own grants on them, the user
  itself and its system privileges. Roles, public synonyms, other users, and synonyms or grants owned
  by other schemas are not owned by it, so they aren't in the file, and the import can't report what it never saw.
- **`ROLE_GRANT` takes no name filter in a full export** (`ORA-31600: invalid input value NAME_EXPR`), and
  unfiltered it also exports role grants for accounts that may not exist on the target. The `fix` drill grants the
  role membership directly; on a real system, generate those statements on the source from `DBA_ROLE_PRIVS`.
- **Run the import with every schema in one job, after the accounts exist.** Data Pump orders the objects inside a
  job; it can't order two jobs for you.

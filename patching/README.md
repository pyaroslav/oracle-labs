# Oracle Patching Inspection Lab (zero-login, read-only)

> 📖 **Companion post:** [Oracle Patching, Demystified: CPU, RU, RUR — and What Changed in 2026](https://uptimearchitect.com/blog/oracle-patching-cpu-ru-rur/)

Read your **patch level**, your **binary patch inventory**, and the **SQL-patch registry** on a real
Oracle database — so the vocabulary in the post (RU, OPatch, `datapatch`, `DBA_REGISTRY_SQLPATCH`) stops
being abstract. Runs on the community **Oracle Database Free** image (currently 26ai). No Oracle account.

> 🔒 **Read-only by design.** This lab *inspects* patch state; it does **not** download or apply any
> Oracle patch. Real Release Updates come from My Oracle Support under a support contract and require a
> licensed Enterprise Edition to apply in production. Here you learn to *read* patch state with the same
> tools you'd use on a patched system — `v$instance.version_full`, `DBA_REGISTRY_SQLPATCH`,
> `opatch lspatches`, `datapatch -verify` — which is exactly the skill the post is about.

## Prerequisites
- Docker + Docker Compose, with ~2 GB free in the Docker engine.

## Quick start
```bash
./run.sh up         # start Oracle Database Free (first run pulls the image + creates the DB)
./run.sh level      # your release/RU level + the SQL-patch registry (DBA_REGISTRY_SQLPATCH)
./run.sh inventory  # the binary patch inventory: opatch lspatches
./run.sh verify     # datapatch -verify — the SQL side, read-only ("what WOULD apply")
./run.sh all        # level + inventory + verify
```
If port 1521 is busy: `LAB_PORT=1530 ./run.sh up`. Everything runs *inside* the container via
`docker exec`, so you don't need a local Oracle client.

## What each command shows
- **`level`** — `version_full` from `v$instance` (the second digit is your RU: `19.26.0.0.0` = RU 26),
  the registry components, and **`DBA_REGISTRY_SQLPATCH`** — the view where `datapatch` records the SQL
  half of every patch. On this base Free image the SQL-patch history is minimal; on a patched production
  database every RU you applied shows up here with `STATUS = SUCCESS`. **This is where you prove
  datapatch actually ran after OPatch.**
- **`inventory`** — `opatch lspatches`, listing the patches OPatch has applied to the **Oracle home**
  (the binary side — "stage 1").
- **`verify`** — `datapatch -verify`, the SQL "stage 2" tool, in **verify mode**: it reports which SQL
  patch actions *would* apply, changing nothing. On a base image it reports nothing pending — which is
  the lesson: binaries and SQL registry are in sync.

## The two-stage mental model this lab makes concrete
A patch goes on in two stages, and forgetting the second is the classic mistake:

1. **OPatch** patches the binaries in the Oracle home → visible in `opatch lspatches`.
2. **datapatch** applies the SQL into the database → recorded in `DBA_REGISTRY_SQLPATCH`.

`inventory` shows stage 1; `level` and `verify` show stage 2. On a correctly patched database the two
agree. When they don't, someone ran OPatch and skipped datapatch — a half-patched, unsupported database.

## Other commands
```bash
./run.sh sql        # SYSDBA SQL*Plus session inside the container
./run.sh down       # stop & remove the container (keeps the data volume)
./run.sh destroy    # stop & remove the container AND the data volume
```

## Connection details
| | |
| --- | --- |
| Host / port | `localhost:${LAB_PORT:-1521}` |
| Pluggable DB | `FREEPDB1` |
| App user | `labuser` / `Lab_Passw0rd1` |
| SYS password | `Lab_Passw0rd1` |

Throwaway lab credentials — never reuse them anywhere real.

## Licensing
Pulls the community `gvenzl/oracle-free` image (Oracle Database Free, under Oracle's Free license for
development). It doesn't redistribute Oracle software — Docker pulls it for you. This lab does not apply
Oracle patches. Oracle® is a registered trademark of Oracle Corporation; this project is independent and
not affiliated with or endorsed by Oracle.

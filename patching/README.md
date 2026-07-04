# Oracle Patching Forensics (no Docker)

> 📖 **Companion post:** [Oracle Patching, Demystified: CPU, RU, RUR — and What Changed in 2026](https://uptimearchitect.com/blog/oracle-patching-cpu-ru-rur/)

The skill that matters in patching isn't running `opatch` — it's **reading patch state** and spotting
when a database *thinks* it's patched but isn't. This lab gives you six realistic situations as command
transcripts (`opatch lspatches`, `v$instance.version_full`, `DBA_REGISTRY_SQLPATCH`) and asks you to
diagnose each one. **No Docker, no database, no Oracle account** — just text and a `grade.sh`.

Why no container? The two facts you diagnose from — the binary patch inventory and the SQL-patch
registry of a *patched* database — don't exist on a throwaway base image (which has no RU applied and
ships without the OPatch tooling). So the honest way to practice is to read real patched-and-broken
states, which is exactly what this lab does.

## What you practice
Comparing the **binary side** (`opatch lspatches` / `version_full`) against the **SQL side**
(`DBA_REGISTRY_SQLPATCH`) and catching the four things that go wrong:
- **OPatch ran, `datapatch` didn't** — binaries ahead of the SQL registry (the classic half-patch).
- **A stale level** — everything consistent, but years of RUs behind.
- **A node mismatch** — RAC homes on different RUs after an unfinished rolling patch.
- **A bad status** — a `DBA_REGISTRY_SQLPATCH` row that's `WITH ERRORS`, not `SUCCESS`.

…plus the vocabulary trap: a runbook that says "apply the RUR" (a track discontinued in 2023).

## Quick start
```bash
# 1. Read the six situations
ls scenarios/                 # 01..06, each a short transcript + a question
#    (or start with exercises.md for the index + the two signals explained)

# 2. Diagnose each one, scored
./grade.sh                    # type your call per scenario, get scored
./grade.sh --show             # just print the answer key
```

Then read [ANSWERS.md](ANSWERS.md) for the full reasoning and the single signal that gives each one away.

## Reading the version number
`release . RU . RUR . reserved . datestamp` → `19.27.0.0.0` = 19c, **RU 27**, no RUR (that digit is
always `0` now — the RUR track is discontinued). The **second field is your patch level.**

## Disclaimer
Personal, educational project. All transcripts are generic and invented for teaching. Nothing here
applies or distributes any Oracle patch. Oracle® is a registered trademark of Oracle Corporation; this
project is independent and not affiliated with, authorized, or endorsed by Oracle.

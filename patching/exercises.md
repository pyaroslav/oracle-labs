# Exercises

Six real patch-state situations. For each, read the transcripts — `opatch lspatches` (the binary
side), `v$instance.version_full` (the level), and `DBA_REGISTRY_SQLPATCH` (the SQL side) — and decide
**what state the database is in and what you'd do**. A couple look fine until you read one column
closely.

| # | Scenario | The tell |
| --- | --- | --- |
| 01 | [Version says patched, registry disagrees](scenarios/01-version-says-patched.md) | Home on 19.27, registry stuck at 19.26 |
| 02 | ["Apply the latest RUR"](scenarios/02-apply-the-latest-rur.md) | The runbook references a track that no longer exists |
| 03 | [Consistent — but the year is 2026](scenarios/03-consistent-but-old.md) | Everything agrees… on a 2023 RU |
| 04 | [opatch, version, and registry all agree](scenarios/04-all-agree.md) | What "done" actually looks like |
| 05 | [Two-node RAC, the nodes disagree](scenarios/05-rac-nodes-disagree.md) | node1 on 19.27, node2 on 19.26 |
| 06 | [datapatch ran — read the STATUS](scenarios/06-datapatch-status.md) | `APPLY` present, but `WITH ERRORS` |

## The two signals, on one line each

- **`opatch lspatches`** — the **binary** side: which RU/patches are in the Oracle *home*. (`version_full`
  reflects this.) This is what **OPatch** owns.
- **`DBA_REGISTRY_SQLPATCH`** — the **SQL** side: which patches `datapatch` has loaded into the
  *database*, with an `ACTION` (APPLY/ROLLBACK) and a `STATUS` (SUCCESS / WITH ERRORS).

A healthy database has the two **agree**. Most patching incidents are one of: the SQL side lagging the
binary side (datapatch skipped), a `STATUS` that isn't SUCCESS, nodes whose homes disagree, or a level
that's simply too old. And "RUR" belongs to no live database at all.

## Reading the version number

`release . RU . RUR . reserved . datestamp` → `19.27.0.0.0` = 19c, **RU 27**, no RUR (that digit is
always 0 now). The **second field is your patch level.**

## Grade yourself

```bash
./grade.sh          # answer each scenario, get scored
./grade.sh --show   # just print the answer key
```

Full reasoning for every scenario — and the single signal that gives it away — is in
[ANSWERS.md](ANSWERS.md).

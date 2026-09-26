# Oracle Labs

Small, runnable Oracle labs that pair with posts on
[uptimearchitect.com](https://uptimearchitect.com) — each one lets you *feel* a concept on your own
machine with nothing but Docker. No Oracle account, no license.

[![labs-e2e](https://github.com/pyaroslav/oracle-labs/actions/workflows/ci.yml/badge.svg)](https://github.com/pyaroslav/oracle-labs/actions/workflows/ci.yml)

## Labs

| Lab | What you do | Post |
| --- | --- | --- |
| [`ha/`](ha/) | Human-error recovery (Flashback), RMAN backup/restore, and block-corruption drills. Plus an opt-in Enterprise Edition [Data Guard module](ha/dataguard/). | *The Oracle HA Decision Tree: RAC vs Data Guard vs Both* |
| [`awr/`](awr/) | Generate a real AWR report from a known workload and read it. | *How to Read an AWR Report Without Drowning* |
| [`wait-events/`](wait-events/) | Reproduce the half-dozen wait events that carry most real problems, and read each signature. | *Oracle Wait Events, Decoded: The Half-Dozen* |
| [`execution-plans/`](execution-plans/) | **Watch a misestimate pick the wrong plan** — build a million-row table with a heavily skewed column, read the real `DBMS_XPLAN` plan (E-Rows vs A-Rows), and prove the optimizer over-estimates the rare value ~1000× and full-scans; then gather a histogram and prove the plan flips to an index range scan with the estimate corrected. Fails the run if the misestimate doesn't reproduce or the fix doesn't correct it. | *Oracle Execution Plans, Decoded: The One Number That Matters* |
| [`optimizer-stats/`](optimizer-stats/) | **Watch correlated columns wreck an estimate** — build a million-row table where `model` determines `make`, and prove the optimizer multiplies selectivities and under-counts ~50× (choosing an index range scan when ~5,000 rows match); then create an extended statistic on the `(make, model)` column group and prove the estimate corrects and the plan flips to a full scan. Fails the run if the under-estimate doesn't reproduce or the column group doesn't fix it. | *Oracle Optimizer Statistics, Demystified* |
| [`deadlock/`](deadlock/) | Trigger a real ORA-00060 deadlock, read the deadlock graph, then fix it with consistent lock ordering. | *ORA-00060 Deadlock: Find It, Fix It, Prevent It* |
| [`vector-search/`](vector-search/) | Run 23ai **AI Vector Search** — a `VECTOR` column + a `VECTOR_DISTANCE` cosine similarity search — on Oracle Database Free, no OCI account. | *Your First Oracle Autonomous Database on OCI Always Free* |
| [`rman/`](rman/) | **Break it and recover it** — delete a datafile then `RESTORE`/`RECOVER` it, repair a corrupt block with block media recovery, and rewind past a bad `DELETE` with point-in-time recovery. Fails the run if the data doesn't come back. | *Oracle RMAN Recovery Runbook: Restore, Recover, Prove It* |
| [`latency/`](latency/) | **Round trips × latency, measured** — run a chatty (1,000 round-trip) and a batched workload against the same database while `tc netem` injects 0ms / 2ms / 10ms of app-to-DB latency, simulating same-datacenter vs the OCI–Azure Interconnect vs cross-region. Fails the run if the numbers don't prove the claim. | *OCI vs Oracle Database@Azure: Where Should Your Oracle Database Live?* |
| [`hardening/`](hardening/) | **The checklist as a test** — stand up a deliberately weak database, score it against six controls (default-password account, `PUBLIC`/`ANY`/`DBA` over-grants, failed-login lockout, unified-auditing baseline), then `harden` and re-audit so every check flips FAIL → PASS. Fails the run if the weak state isn't weak or hardening leaves a gap. | *The Oracle Hardening Checklist That Actually Matters* |
| [`unified-auditing/`](unified-auditing/) | **Prove your policies capture** — enable the baseline (`ORA_SECURECONFIG` + `ORA_LOGON_FAILURES`) plus a custom policy, trigger a failed login, a `CREATE USER`, and a read of a sensitive table, flush the buffer, then assert each landed in `UNIFIED_AUDIT_TRAIL`. Fails the run if any triggered event wasn't recorded. | *Oracle Unified Auditing Without the Noise* |
| [`tde/`](tde/) | **Read the datafile off disk** — write identical canary rows into one `ENCRYPTION USING 'AES256'` tablespace and one ordinary one, flush to disk, then `grep` both `.dbf` files: the canary is present in the plaintext file and absent from the encrypted one. Then close the keystore and prove the database itself can't read the encrypted table (ORA-28365) until the wallet reopens. Fails the run if the canary shows up encrypted or the wallet close doesn't block reads. | *Oracle Transparent Data Encryption: Prove the Datafile Is Unreadable* |
| [`data-redaction/`](data-redaction/) | **Mask at read time, then prove it isn't access control** — protect one table with a four-column `DBMS_REDACT` policy and read it as a subject `CLERK` (masked) and an `EXEMPT` `AUDITOR` (real values). Then `grep` the datafile to show the real card numbers are still on disk (redaction ≠ encryption), and show a `WHERE` clause on the true value still matches (redaction ≠ access control). Fails the run if the clerk sees plaintext, the auditor sees masks, or the data isn't on disk. | *Oracle Data Redaction: Mask at Read Time, Prove It Isn't Access Control* |
| [`partition-pruning/`](partition-pruning/) | **Read one partition, not the whole table** — build a 1.2M-row table with 24 monthly partitions and run the same "June 2025" count two ways: a range predicate on the key prunes to `PARTITION RANGE SINGLE` (one partition, 1,725 buffers), while a `TO_CHAR()` on the key defeats pruning into `PARTITION RANGE ALL` (all partitions, 41,448 buffers). Same 50,000 rows, ~24× the work. Fails the run if pruning doesn't happen, the counts differ, or the buffer saving isn't there. | *Oracle Partition Pruning: Read One Partition, Not the Whole Table* |
| [`data-pump/`](data-pump/) | **A migration you can prove** — build a 5,000/20,000-row schema, `expdp` it, then drop-and-`impdp` it back (lossless round trip, row counts asserted), `impdp REMAP_SCHEMA` into a new schema, and a parfile-driven `INCLUDE=TABLE` export that lands only the chosen table. Fails the run if the round trip loses a row, the remap counts differ, or the filter leaks a table. | *Oracle Data Pump, Done Right: A Migration You Can Prove* |
| [`indexes/`](indexes/) | **When an index helps, when it hurts** — a 1,000,000-row skewed `ORDERS` table, indexed on a selective column and a low-cardinality one. Proves a selective query drops from a 17,834-buffer full scan to a **14-buffer** index range scan; the same `status` index is **ignored** for the 95% value (full scan) but **used** for the 0.1% value; and forcing it on the common value reads **19,459** buffers — *more* than the full scan it replaced. Selectivity decides, and the plan proves it. | *Oracle Indexes: When They Help, When They Hurt, and How to Tell* |
| [`bind-variables/`](bind-variables/) | **The hard-parse storm** — run one logical query (`select count(*) ... where id = <n>`) 1,000 times two ways and read `V$SQL` / `V$MYSTAT`: with **literals** it's **1,000** parent cursors, **1,001** hard parses, and **~38 MB** of shared pool; with a **bind** (`:b`) it's **1** cursor, **1** hard parse, **~39 KB**, and 1,000 executions of that one cursor. Same answer, ~1000× the parsing and memory. Fails the run if literals don't explode or the bind doesn't collapse to one. | *Bind Variables: The Hard-Parse Storm That Melts Your Shared Pool* |
| [`privilege-analysis/`](privilege-analysis/) | **What they were granted vs what they used** — grant a user a role carrying 12 privileges (incl. `SELECT ANY TABLE`, `DROP ANY TABLE`), capture a tiny workload with `DBMS_PRIVILEGE_CAPTURE`, then report USED (`CREATE SESSION`, `CREATE TABLE`, `SELECT` on one table) vs the 9 UNUSED. Asserts the scary `ANY` privileges land in unused — the least-privilege revoke list, from evidence. Caps the security series (right-size the grants themselves). | *Oracle Privilege Analysis: You Granted DBA. Here's What They Actually Used* |
| [`vpd/`](vpd/) | **Row-level security you can't route around** — put a `DBMS_RLS` (Virtual Private Database) policy on a 3,000-row `ORDERS` table (1,800 EAST / 1,200 WEST) and read it as three users: `REP_EAST` sees only its 1,800 EAST rows, `REP_WEST` only its 1,200 WEST rows, and `MGR` (holding `EXEMPT ACCESS POLICY`) sees all 3,000. Asserts the predicate is enforced on counts, on `SUM(amount)`, and on a targeted `WHERE id=` lookup — so a rep can't reach another region's row even by asking for it. Fails the run if any reader sees a row it shouldn't. The row-level counterpart to the column-masking `data-redaction` lab. | *Oracle Virtual Private Database: Row-Level Security You Can't Route Around* |
| [`flashback/`](flashback/) | **Undo, one layer at a time** — reverse a bad `UPDATE` with Flashback Query and `FLASHBACK TABLE ... TO SCN`, resurrect a dropped table from the recycle bin with `FLASHBACK TABLE ... TO BEFORE DROP`, and rewind the whole database past a disaster with a guaranteed restore point and `FLASHBACK DATABASE`. Fails the run if any layer doesn't come back. | *Oracle Flashback: Undo at the Database Level* |
| [`snapshot-too-old/`](snapshot-too-old/) | **Reproduce ORA-01555, then make it impossible** — a full-scan query pins its read-consistent snapshot, then heavy DML rewrites every row 12× on a tiny (25 MB, no-autoextend, `NOGUARANTEE`) undo tablespace, overwriting the undo the query needs → **ORA-01555**. Swap in a 300 MB undo tablespace with `RETENTION GUARANTEE` + `undo_retention=1200` and the **same** query reads all 20,000 rows. Fails the run if the error doesn't reproduce or the fix doesn't cure it. | *ORA-01555 Snapshot Too Old: Reproduce It, Then Make It Impossible* |
| [`archiver-stuck/`](archiver-stuck/) | **Reproduce ORA-00257, then clear it** — an ARCHIVELOG-mode database archives into a deliberately tiny 50 MB Fast Recovery Area; a little redo plus a couple of log switches fill it, archive destination 1 goes to **ERROR** (`ORA-19809`), the online logs fill, and a normal (non-SYSDBA) user is refused with **ORA-00257** while SYSDBA still connects. RMAN backs the archived logs up **outside** the FRA and deletes the inputs, the FRA is grown, and the same user writes again. Fails the run if the outage doesn't reproduce or the fix doesn't clear it. | *ORA-00257: The Database Stopped Accepting Writes. The Archiver Is Stuck.* |
| [`charset-migration/`](charset-migration/) | **Reproduce silent character-set data loss, then prevent it** — 10 customer names (5 ASCII, 5 with accents/CJK) in an AL32UTF8 database, "migrated" into a narrower target set with `CONVERT`. A **US7ASCII** target keeps all 10 rows and raises no error, yet **damages 5 of 10 names** (`José`→`Jose`, CJK→`??`); **WE8MSWIN1252** still loses the CJK name; **AL32UTF8** loses nothing. A round-trip scan flags the lossy rows before cutover. Fails the run if the loss doesn't reproduce or the Unicode target isn't clean. | *The Migration Completed Successfully. Half the Names Are Now Question Marks.* |
| [`patching/`](patching/) | **No Docker** — diagnose 6 patch-state situations from their transcripts: the `datapatch` gap, a stale RU, a RAC node mismatch, a `WITH ERRORS` status, and the "apply the RUR" trap. `./grade.sh` self-check. | *Oracle Patching, Demystified: CPU, RU, RUR — and What Changed in 2026* |
| [`ha/rac-eviction/`](ha/rac-eviction/) | **No Docker** — diagnose 5 realistic RAC node-eviction scenarios from their logs (interconnect, voting disk, starvation, time drift, and one that isn't an eviction at all). | *RAC Node Eviction: A Troubleshooting Checklist That Starts With Why* |
| [`ha/dataguard-switchover/`](ha/dataguard-switchover/) | **No Docker** — read 5 Data Guard Broker situations and decide switchover vs failover, the data loss, and the old-primary aftermath. | *Data Guard Switchover vs Failover: Which Role Transition, and When* |
| [`migration-methods/`](migration-methods/) | **No Docker** — pick the right migration method (Data Pump, GoldenGate, Data Guard, ZDM…) across 5 scenarios; `./grade.sh` self-check. | *Migrating Oracle to the Cloud: Which Method, and When* |

Each Docker lab is verified end-to-end in CI. The `rac-eviction` and `dataguard-switchover` labs are
self-contained, text-only forensics exercises (just bash) — run `./grade.sh` to self-check.

## Quick start

```bash
cd ha    # or: cd awr
./run.sh up        # start Oracle Database Free (first run pulls the image + creates the DB)
./run.sh all       # run the lab end to end
```

See each lab's own `README.md` for the full guide, expected output, and troubleshooting. No local
Docker / not enough RAM? The HA lab includes [`ha/CLOUD.md`](ha/CLOUD.md) to run it free on an OCI
Always Free VM.

## What these labs deliberately don't cover

RAC (shared storage + cluster interconnect) and Data Guard (managed standby) are Enterprise Edition
capabilities that don't run on the zero-login Free image — so the labs focus on what you *can* reproduce
on a laptop. The opt-in [`ha/dataguard/`](ha/dataguard/) module documents a real Data Guard setup for
when you have EE access. And while you can't spin up a real cluster on a laptop, you *can* practice the
skill that matters when one breaks — diagnosing a node eviction from the logs — in the no-Docker
[`ha/rac-eviction/`](ha/rac-eviction/) forensics lab.

## Disclaimer

Personal, educational projects. All data is generic and invented. Oracle® is a registered trademark of
Oracle Corporation; these projects are independent and not affiliated with, authorized, or endorsed by
Oracle. The labs pull the community `gvenzl/oracle-free` image (Oracle Database Free, under Oracle's
Free license) — review Oracle's license terms for your use.

## License

[MIT](LICENSE).

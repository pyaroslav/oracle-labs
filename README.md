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
| [`deadlock/`](deadlock/) | Trigger a real ORA-00060 deadlock, read the deadlock graph, then fix it with consistent lock ordering. | *ORA-00060 Deadlock: Find It, Fix It, Prevent It* |
| [`vector-search/`](vector-search/) | Run 23ai **AI Vector Search** — a `VECTOR` column + a `VECTOR_DISTANCE` cosine similarity search — on Oracle Database Free, no OCI account. | *Your First Oracle Autonomous Database on OCI Always Free* |
| [`rman/`](rman/) | **Break it and recover it** — delete a datafile then `RESTORE`/`RECOVER` it, and rewind past a bad `DELETE` with point-in-time recovery. Fails the run if the data doesn't come back. | *Oracle RMAN Recovery Runbook: Restore, Recover, Prove It* |
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

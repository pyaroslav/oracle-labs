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

Each lab is verified end-to-end in CI.

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
when you have EE access.

## Disclaimer

Personal, educational projects. All data is generic and invented. Oracle® is a registered trademark of
Oracle Corporation; these projects are independent and not affiliated with, authorized, or endorsed by
Oracle. The labs pull the community `gvenzl/oracle-free` image (Oracle Database Free, under Oracle's
Free license) — review Oracle's license terms for your use.

## License

[MIT](LICENSE).

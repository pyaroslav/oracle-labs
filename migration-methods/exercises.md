# Exercises

For each scenario, decide the **single best migration method** and be able to justify it. Work them
in order — they're arranged to walk the decision space, and a couple contain a deliberate trap.

| # | Scenario | The question |
| --- | --- | --- |
| 01 | [Lift-and-shift to OCI](scenarios/01-lift-and-shift-to-oci.md) | Same arch, large, near-zero RTO, wants fallback |
| 02 | [Off big-endian Solaris](scenarios/02-off-big-endian-solaris.md) | Cross-endian, very large, weekend window, no GoldenGate |
| 03 | [Into Autonomous Database](scenarios/03-into-autonomous.md) | Managed target, non-Unicode source, window OK |
| 04 | [Oracle Database@Azure](scenarios/04-database-at-azure.md) | "It's Azure, so logical-only" — true or false? |
| 05 | [Cross-endian, near-zero, fallback](scenarios/05-cross-endian-near-zero.md) | Cross-endian + cross-version + near-zero + fallback |
| 06 | [Standard Edition source](scenarios/06-standard-edition.md) | The inherited plan says "Data Guard" — can you? |

## The method, on one line each

- **Data Pump** — logical export/import; crosses *any* boundary; downtime ∝ size; the only way *into Autonomous*.
- **Transportable / XTTS** — copy datafiles + metadata; cross-endian via `RMAN CONVERT`; incrementals shrink the outage; very large DBs.
- **Data Guard** — physical standby → switchover; near-zero downtime + easy rollback; **same endian + same version + Enterprise Edition**.
- **GoldenGate** — logical replication; near-zero downtime across *any* boundary; bidirectional fallback; separately licensed; complex.
- **ZDM** — free Oracle tool that *orchestrates* the above (physical = Data Guard/RMAN; logical = Data Pump/GoldenGate).

## Grade yourself

```bash
./grade.sh          # answer each scenario, get scored
./grade.sh --show   # just print the answer key
```

Full reasoning for every scenario is in [ANSWERS.md](ANSWERS.md).

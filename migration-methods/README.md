# Oracle Cloud-Migration Method-Selection Lab (zero-install)

> 📖 **Companion post:** [Migrating Oracle to the Cloud: Which Method, and When](https://uptimearchitect.com/blog/oracle-cloud-migration-methods/)

Choosing *how* to move an Oracle database to the cloud is the decision that actually sets your
downtime, risk, and rollback — far more than choosing *where*. This lab drills that decision: **six
realistic migration scenarios**, each with a source platform/version/size, a target (OCI, Oracle
Database@Azure, or Autonomous), a downtime budget, and an edition — and you pick the single best method
and justify it. A couple of scenarios contain a deliberate trap that real teams fall into.

It's a **no-install, runs-anywhere** lab (just bash): annotated scenario briefs, a worked answer key,
and a `grade.sh` self-check. No Oracle binaries, no cloud account — the methods themselves (Data Guard
into the cloud, GoldenGate, XTTS, ZDM) need Enterprise Edition and real cloud targets, so this lab
trains the **judgment**, not the keystrokes.

## How to use it

1. Read [`exercises.md`](exercises.md) for the scenario list and a one-line refresher on each method.
2. Work each scenario in [`scenarios/`](scenarios/) — decide the best method and *why*.
3. Check yourself:

```bash
./grade.sh          # answer each scenario, get scored out of 6
./grade.sh --show   # just print the answer key
```

4. Read [`ANSWERS.md`](ANSWERS.md) for the full reasoning, including the giveaway constraint in each.

## What it teaches

The four gates that decide every Oracle cloud migration, in order: **(1)** what the target allows
(Autonomous = logical only; Exadata/Base DB/Database@Azure = everything), **(2)** whether you're
crossing endianness or version (physical methods can't), **(3)** the downtime budget (near-zero vs
outage), and **(4)** edition and licensing (Data Guard needs Enterprise Edition; GoldenGate is extra).

---

Oracle® is a registered trademark of Oracle Corporation; this project is independent and not affiliated
with or endorsed by Oracle. The scenarios are invented for teaching and contain no real customer data.

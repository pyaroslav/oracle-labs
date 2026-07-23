# Interconnect-latency lab — round trips × latency, measured

Companion to [OCI vs Oracle Database@Azure: Where Should Your Oracle Database
Live?](https://uptimearchitect.com/blog/oracle-database-at-azure-vs-oci/)

The post's latency tiebreaker in one experiment: **a chatty workload pays (round trips × latency)
every single time; a batched workload barely notices.** This lab runs both workloads against the
same Oracle Database Free container while `tc netem` injects the app-to-database latency of three
possible homes:

| Injected delay | Simulates |
| --- | --- |
| 0ms | same datacenter — Database@Azure next to your Azure apps, or app-in-OCI next to an OCI DB |
| 2ms | the OCI–Azure Interconnect between paired regions |
| 10ms | a generic cross-region / cross-cloud path |

Two containers: `oracle` (the database) and `app` (same image, DB not started — just its
`sqlplus`, plus `NET_ADMIN` so netem can shape its egress). The **chatty** workload issues 1,000
single-row statements (~1,000 `SQL*Net roundtrips to/from client`, the shape of row-by-row ORM
traffic); the **batched** workload fetches the same 1,000 rows in one statement with
`arraysize 500` (a handful of round trips).

## Run it

```bash
./run.sh up                  # start database + app (first run pulls the image)
./run.sh all                 # setup + baseline + interconnect + wan + summary table
```

Or drill by drill:

```bash
./run.sh setup               # schema, v$ grants, tc install, connectivity check
./run.sh drill-baseline      # 0ms:  verifies the workload shapes (chatty ≥900 rt, batched ≤60 rt)
./run.sh drill-interconnect  # 2ms:  chatty must pay ≥1.2s extra; batched must stay ~flat
./run.sh drill-wan           # 10ms: chatty must pay ≥6s extra; batched still ~flat
./run.sh sql                 # SQL*Plus from the app container, through the injected latency
```

Every drill **fails loudly** if the numbers don't prove the claim — the round-trip counts are read
from `v$mystat`, not assumed, and the elapsed-time deltas are asserted against the injected delay.

## What you should see

The summary table at the end looks like this (times vary with hardware; the *shape* doesn't):

```
scenario               workload   elapsed_ms    round_trips
0ms same-datacenter    chatty           ~2000          ~1000
0ms same-datacenter    batched            ~40             ~5
2ms interconnect       chatty           ~4000          ~1000
2ms interconnect       batched            ~50             ~5
10ms cross-region      chatty          ~12000          ~1000
10ms cross-region      batched            ~90             ~5
```

Same database, same rows. The chatty workload's penalty is almost exactly *round trips × injected
delay* — which is why "2ms is nothing" is only true for applications that don't multiply it, and
why the blog post tells you to measure your app's round-trip count before choosing where the
database lives.

## Cleanup

```bash
./run.sh down     # stop containers, keep the data volume
./run.sh destroy  # remove everything including the volume
```

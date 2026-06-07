# Answer Key

Spoilers. Try `exercises.md` first.

---

## Scenario 01 — Interconnect (network heartbeat)
- **Heartbeat:** Network.
- **Root cause:** Private interconnect packet loss / link flap on `eth1` (jumbo MTU 9000; access-switch
  port flapping). The interconnect, not the database, failed.
- **Immediate fix:** Restore the link (fix/replace the switch port or cable); node2 rejoins after CSS
  reconfig once heartbeats resume.
- **Prevention:** Redundant private NICs (HAIP or bonding), a dedicated interconnect, **validated**
  jumbo frames end-to-end (`ping -M do -s 8972`), and no app/backup traffic sharing the link.
- **The tell:** `clssnmDoSyncUpdate: Terminating node 2 ... misstime(30000)` → **misscount (30s)**,
  the *network* timeout. Confirmed by `clssnmCheckDskInfo: node(2) is down ... Disk lastSeqNo(...)` —
  node2 was **still writing its voting-disk heartbeat**, so the disk path was fine; only the network
  was gone. The rising `RX-DRP` on eth1 seals it.

## Scenario 02 — Voting disk (disk heartbeat)
- **Heartbeat:** Disk.
- **Root cause:** node2 lost all multipath paths to the LUN backing voting file `vfile2`; with only 1
  of 3 voting files visible it could not hold the required majority (2).
- **Immediate fix:** Restore the storage path (multipath/SAN); ASM brings the disk back, CSSD restarts,
  node2 rejoins.
- **Prevention:** Voting files across **independent** failure groups/paths; healthy multipathing;
  alert on path loss and voting-file I/O latency.
- **The tell:** `CRS-1606: The number of voting files available, 1, is less than the minimum ... 2,
  resulting in CSSD termination` — governed by **`disktimeout` (~200s)**, *not* misscount. Network was
  healthy (no `clssnmPollingThread` fatals). OS log: `multipathd ... remaining active paths: 0`.

## Scenario 03 — Resource starvation (local heartbeat)
- **Heartbeat:** Local — `ocssd` was alive but **couldn't get scheduled** to send heartbeats.
- **Root cause:** A runaway non-DB process (`java` pid 30771) consumed all CPU and memory; the node
  thrashed in swap (swap 99%, 0% CPU idle), starving `ocssd` off the run queue. It *looked* like a
  network miss from node1.
- **Immediate fix:** Relieve the pressure (kill/contain the runaway); the node reboots via the local
  guardian and rejoins.
- **Prevention:** CPU/memory **headroom** on every node; don't co-locate greedy workloads with the DB;
  run **CHM/OSWatcher** so you can prove it next time. Diagnose the load itself like any perf problem —
  see *How to Read an AWR Report*.
- **The tell:** `cssagent ... Rebooting node to ensure cluster integrity (local OCSSD not schedulable)`
  and `ocssd main thread last scheduled 26.8s ago` — plus CHM showing **load 270, 0% idle, swap 99%**.
  The interconnect NIC was **clean**. **You needed CHM/OSWatcher running beforehand** to prove this;
  without it, by morning the evidence is gone and you'd have wrongly blamed the network.

## Scenario 04 — Time synchronization
- **Heartbeat:** Network heartbeat *accounting* was disrupted by a clock jump (not a real network loss).
- **Root cause:** chrony was restarted on node2 and allowed the clock to **STEP** by ~7s while CSS was
  running, corrupting heartbeat time accounting and triggering a reconfiguration/eviction.
- **Immediate fix:** Stabilize time on node2 (let it slew, not step); node2 rejoins.
- **Prevention:** Consistent NTP/chrony across all nodes configured to **slew** (avoid large steps)
  while the cluster is up; or let `ctssd` run in active mode if no external sync. Don't bounce time
  services on a running cluster node.
- **The tell:** hours of `CRS-2409: The clock on host node2 is not synchronous with the mean cluster
  time` (early warning, observer mode), then `chronyd ... STEP applied` immediately before
  `clssnmHandleSync ... local LATS jumped backward ~7s`. NIC clean; voting files all online.

## Scenario 05 — Hardware / OS — **NOT a Clusterware eviction**
- **Heartbeat:** None failed gradually. **This is the trap: node2 was not evicted *by* a heartbeat
  miss — it died, and CSS evicted a node that was *already gone* to complete reconfiguration.**
- **Root cause:** An **uncorrectable ECC memory error** (MCE on DIMM B2) reset/powered node2 — a
  hardware fault, outside Clusterware entirely.
- **Immediate fix:** Hardware remediation (replace DIMM B2); node2 boots and rejoins (it did, cleanly).
- **Prevention:** Proactive hardware health monitoring (ILOM/IPMI, EDAC/MCE alerts), firmware currency.
- **The tell:** the GI log has **no decay curve** — no `CRS-1610/1611/1612` (network) and no
  `CRS-1604/1606` (voting) warnings, unlike every other scenario. node2 "disappeared between one
  heartbeat and the next," rejoined with no recorded cause, and the **OS/ILOM logs show the MCE +
  unclean shutdown**. Lesson: **not every node loss is a Clusterware eviction** — always reconcile the
  GI logs against the OS/hardware logs before blaming the cluster.

---

### The meta-lesson
Three of these (01, 03, 04) show node1 logging what *looks* like a network problem. Only the **other**
sources — voting-disk state, CHM/OSWatcher, OS/ILOM logs — tell you which it really was. That's why the
read order is GI alert log → ocssd → cssdagent → OS → CHM/OSWatcher, and why CHM/OSWatcher must be
running *before* the incident.

# Exercises

For each scenario, read `scenarios/NN-*/logs.txt` **before** looking at `ANSWERS.md`. Write down your
answers to these four questions, then run `./grade.sh` (or read the key).

For every scenario:

1. **Which heartbeat failed** — Network (interconnect), Disk (voting files), Local (`ocssd`
   starved/hung) — **or was this not an eviction at all?**
2. **What is the root cause?** (one phrase)
3. **What is the immediate fix** to get the node back safely?
4. **What is the prevention** so it doesn't recur?

Bonus, every scenario: **name the single log line that gave it away.**

---

### Scenario 01 — `scenarios/01-interconnect/`
The survivor's GI log shows node2 decaying 50% → 75% → 90% then evicted. What failed, and how do you
know it wasn't the voting disk?

### Scenario 02 — `scenarios/02-voting-disk/`
node2 aborted CSSD itself. Which timeout governed this (`misscount` or `disktimeout`), and why did
node1 survive while node2 didn't?

### Scenario 03 — `scenarios/03-starvation/`
From node1, this looks exactly like Scenario 01 (a network miss). Prove it wasn't — and say what you'd
have needed *running beforehand* to prove it at all.

### Scenario 04 — `scenarios/04-time-drift/`
There are `CRS-2409` messages hours before the eviction. What changed on node2 that morning, and what's
the difference between a clock **slew** and a clock **step** here?

### Scenario 05 — `scenarios/05-os-hardware/`
The trap. Is this even a Clusterware eviction? What's missing from the GI alert log that's present in
scenarios 01–04, and what actually happened to node2?

---

Self-check: `./grade.sh`  ·  Full reasoning: `ANSWERS.md`

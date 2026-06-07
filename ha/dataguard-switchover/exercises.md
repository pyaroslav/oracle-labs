# Exercises

Read each `scenarios/NN-*/transcript.txt` **before** `ANSWERS.md`. For every scenario, answer:

1. **Switchover, failover — or neither (yet)?** Apply the one-sentence test: is the primary healthy and
   reachable?
2. **The exact action / Broker command.**
3. **What happens to the old primary** afterward?
4. **Data loss** — how much, and what does the protection mode say about it?

Bonus: **name the line in the transcript that decided it.**

---

### Scenario 01 — `01-planned-maintenance/`
Healthy primary, planned OS patch, standby in sync. Which transition, and is it reversible?

### Scenario 02 — `02-primary-lost-manual/`
Primary host is dead and FSFO is off. Switchover or failover? What's the command, and what will you have
to do for the old primary when it's repaired? Given MaxAvailability + the standby was synchronized — how
much data did you lose?

### Scenario 03 — `03-fsfo-auto-failover/`
You didn't run anything yet. Read the config: **who is the primary now**, what happened at 03:11, and
what's the one action still outstanding?

### Scenario 04 — `04-protection-mode-loss/`
The bridge wants a number. With MaxPerformance and a 14s transport lag / 22s apply lag at failure —
**roughly how much data is lost** on failover, and which of those two lags is the data-loss figure? What
configuration would have made it zero?

### Scenario 05 — `05-switchover-blocked/`
The switchover refused but the primary is fine. Why did it fail, what do you fix before retrying, and is
this a failover situation? (Hint: transport lag vs apply lag.)

---

Self-check: `./grade.sh`  ·  Full reasoning: `ANSWERS.md`

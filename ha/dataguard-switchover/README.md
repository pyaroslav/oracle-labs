# Data Guard Switchover vs Failover Forensics Lab (zero-install)

> 📖 **Companion post:** [Data Guard Switchover vs Failover](https://uptimearchitect.com/blog/oracle-data-guard-switchover-vs-failover/)

Practice the decision that matters in a Data Guard incident: **switchover or failover — and what to do
about the old primary afterward.** This is the hands-on companion to the post
**"Data Guard Switchover vs Failover: Which Role Transition, and When."**

No standby, no Enterprise Edition, no license — just `DGMGRL` transcripts. You read **five realistic
Broker situations**, decide the correct action, and check your answer.

> ⚠️ **The transcripts in this lab are synthetic — invented for teaching.** They mimic the shape of real
> `DGMGRL` (Data Guard Broker) output, but are not captured from a real system. Real output varies by
> version; treat exact wording as illustrative.

## Why a forensics lab (and not a live standby)
Data Guard is an **Enterprise Edition** feature — it doesn't run on the zero-login `gvenzl/oracle-free`
image the other Docker labs use. To stand up a *real* physical standby and run actual role transitions,
see the opt-in EE module in [`../dataguard/`](../dataguard/) (bring your own EE binaries). This lab
drills the *decision* skill, which is the part that actually goes wrong under pressure.

## The method (the whole game)
For each scenario, apply the **one-sentence test** and answer:

1. **Is the primary healthy and reachable?** Yes + planned → **switchover**. No (gone/unreachable) →
   **failover**. (And sometimes: neither yet — a precondition isn't met.)
2. **What's the exact action / Broker command?**
3. **What happens to the old primary?** (Reinstate via Flashback? Rebuild?)
4. **How much data loss** — and what does the **protection mode** say about it?

Remember: **transport lag = data-loss exposure** (redo not yet received); **apply lag = staleness /
recovery time** (received but not applied). They are not the same number.

## How to use
```bash
less scenarios/01-planned-maintenance/transcript.txt   # read the Broker output
# answer the questions in exercises.md, then:
./grade.sh            # prompts you for the correct action per scenario, scores you
./grade.sh --show     # reveal the answer key
less ANSWERS.md       # full reasoning + the giveaway line
```

## The scenarios
| # | Folder | Teaches |
|---|---|---|
| 1 | `scenarios/01-planned-maintenance`   | healthy primary, planned work → **switchover** |
| 2 | `scenarios/02-primary-lost-manual`   | primary gone, FSFO off → **manual failover** |
| 3 | `scenarios/03-fsfo-auto-failover`    | the Observer already failed over → **reinstate** the old primary |
| 4 | `scenarios/04-protection-mode-loss`  | quantifying failover **data loss** from the protection mode + transport lag |
| 5 | `scenarios/05-switchover-blocked`    | a switchover that **refuses** — the standby isn't caught up (precondition) |

## Graduating to a real standby
For real `SWITCHOVER`/`FAILOVER`/`REINSTATE` against an actual physical standby, build the EE Data Guard
setup in [`../dataguard/`](../dataguard/) (your own Oracle EE binaries; not redistributable).

---
Part of [github.com/pyaroslav/oracle-labs](https://github.com/pyaroslav/oracle-labs). Companion to the
post on uptimearchitect.com.

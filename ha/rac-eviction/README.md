# Oracle RAC Node-Eviction Forensics Lab (zero-install)

> 📖 **Companion post:** [RAC Node Eviction: A Troubleshooting Checklist](https://uptimearchitect.com/blog/oracle-rac-node-eviction-troubleshooting/)

Practice the skill that actually matters when a RAC node disappears: **reading the logs and naming the
cause.** This is the hands-on companion to the post
**"RAC Node Eviction: A Troubleshooting Checklist That Starts With Why."**

No cluster, no Docker, no Oracle account, no license — just text. You triage **five realistic eviction
scenarios** from their logs, decide *which heartbeat failed and why*, then check your answer.

> ⚠️ **The logs in this lab are synthetic — invented for teaching.** They mimic the *shape* and key
> signatures of real Oracle Clusterware / CSS / OS output (12c–19c style messages), but they are not
> captured from any real system. Real logs vary by version and are noisier; treat exact wording as
> illustrative, not canonical.

## Why a forensics lab (and not a live cluster)
Recovering from an eviction is mostly **diagnosis** — find the failed heartbeat — plus fixing the
upstream fault. A real 2-node RAC needs ~20 GB+ RAM and Enterprise Edition binaries, so it won't run on
most laptops. The *transferable* skill is the log-reading, and that's exactly what this drills. (Want
the real cluster? See "Graduating to a real cluster" at the bottom.)

## The diagnostic method (the whole game)
For each scenario, read the logs **in this order** and answer four questions:

1. **Which heartbeat failed?** Network (interconnect, `misscount` ≈30s) · Disk (voting files,
   `disktimeout` ≈200s) · Local (`ocssd` starved/hung) — **or was it an eviction at all?**
2. **Root cause?** Interconnect, storage/voting, resource starvation, time sync, or hardware/OS.
3. **Immediate fix?**
4. **Prevention?**

Read order: **GI alert log → `ocssd` trace → `cssdagent`/`cssdmonitor` → OS messages → CHM/OSWatcher.**

## How to use
```bash
# 1. Pick a scenario and read its logs:
less scenarios/01-interconnect/logs.txt

# 2. Answer the questions in exercises.md (write your answers down).

# 3. Self-check interactively:
./grade.sh                # prompts you for the root cause of each scenario, scores you
./grade.sh --show         # just reveal the answer key

# 4. Read the full reasoning:
less ANSWERS.md
```

## The scenarios
| # | Folder | Don't peek — but it teaches… |
|---|---|---|
| 1 | `scenarios/01-interconnect` | the classic: network heartbeat loss on the private interconnect |
| 2 | `scenarios/02-voting-disk`  | self-eviction when voting-disk majority is lost |
| 3 | `scenarios/03-starvation`   | a starved node that *looks* like a network problem but isn't |
| 4 | `scenarios/04-time-drift`   | clock skew destabilizing membership |
| 5 | `scenarios/05-os-hardware`  | a reboot that **isn't** a Clusterware eviction at all |

## Graduating to a real cluster
To actually *trigger and recover from* evictions (pull the interconnect, block a voting disk, starve a
node, then `crsctl` it back), you need a real cluster. The legal, supported path is Oracle's own
**RAC-on-Docker** (`oracle/docker-images`) or the **OracleRAC Vagrant box** (`oracle/vagrant-projects`)
— you supply your own Oracle binaries (they are **not** redistributable), and you'll want a 32 GB+ host.
A future `oracle-rac-lab` subproject will layer eviction exercises on top of that build.

---
Part of [github.com/pyaroslav/oracle-labs](https://github.com/pyaroslav/oracle-labs). Companion to the
blog post on uptimearchitect.com.

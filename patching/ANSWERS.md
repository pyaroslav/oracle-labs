# Answer key — with reasoning

Every patch-state question comes down to comparing two facts and reading them in context:

1. **The binary side** — `opatch lspatches` / `version_full`: which RU is in the Oracle *home*.
2. **The SQL side** — `DBA_REGISTRY_SQLPATCH`: which patches `datapatch` loaded into the *database*, and
   with what `STATUS`.

Then two sanity checks around them: is the level actually *current*, and (on RAC) do all nodes' homes
*agree*? That's the whole diagnostic surface.

---

## 01 — Version says patched, registry disagrees → **run `datapatch`**

The classic half-patched database. OPatch installed RU 19.27 in the home, so the binaries — and
`version_full` — read 19.27. But `DBA_REGISTRY_SQLPATCH` tops out at **19.26**: the **SQL half of the
19.27 patch never ran**. Patching is two stages — OPatch (binaries) *then* datapatch (dictionary SQL) —
and the change closed after stage one. Until you run `datapatch`, the dictionary and the binaries are
out of step; that's an unsupported state and the likely cause of the "odd behavior." Fix: connect and
run `$ORACLE_HOME/OPatch/datapatch -verbose`, then confirm the 19.27 row appears with `STATUS = SUCCESS`.
**The tell:** `version_full` newer than the newest `DBA_REGISTRY_SQLPATCH` row.

## 02 — "Apply the latest RUR" → **there is no RUR to apply; stay on the latest RU (use an MRP between quarters)**

The runbook is describing a track Oracle **discontinued after January 2023**. Release Update Revisions
were the old "security + critical-regression fixes only" option layered on a prior RU — the third digit
of the version number (`19.24.1`). That program is gone; the third digit is now permanently `0`. What
replaced it for staying current *between* quarterly RUs is the **Monthly Recommended Patch (MRP)** (19c,
Linux x86-64). So: you can't download "the latest 19.24 RUR" because none exists. Rewrite the runbook to
**apply the latest RU** each quarter, and — if the goal is fresher fixes without waiting a full quarter
— add the latest **MRP**, or (from 2026) track the monthly **CSPU** security releases. **The tell:** any
current process that names "RUR" is stale by definition.

## 03 — Consistent but old → **not adequately patched; it's ~8+ quarters behind — schedule the latest RU**

This one is internally *clean* — binaries, `version_full`, and the SQL registry all agree on 19.18 — and
that's exactly the trap. **"Fully applied" is not "current."** 19.18 is the **January 2023** RU; in 2026
that's on the order of a dozen quarterly Release Updates behind, i.e. years of accumulated security and
regression fixes missing. A consistent registry only proves *both stages of that old RU* completed — it
says nothing about whether the RU itself is recent. Diagnosis: out of date; plan and test the jump to the
latest RU. **The tell:** read the RU digit against the calendar — `19.18` in 2026 is old, no matter how
consistent the registry is.

## 04 — Everything agrees, current quarter → **nothing to do; this is "done"**

`opatch lspatches` shows RU 19.27, `version_full` is 19.27.0.0.0, and `DBA_REGISTRY_SQLPATCH` carries the
19.27 `APPLY` row with `STATUS = SUCCESS`. Binary side and SQL side agree, both stages clean. No
`datapatch` gap, no error status, single instance so no node mismatch. Close the change. This scenario
exists so the other five have a baseline: **this** is the picture the others deviate from. (Whether 19.27
is also the *newest* RU available is a separate question — that's scenario 03.) **The tell:** newest
`opatch` RU == newest `SQLPATCH` RU, `STATUS = SUCCESS`.

## 05 — RAC nodes disagree → **rolling patch left unfinished; patch node 2's home, then run `datapatch` once**

A rolling patch applies the RU to **one node's home at a time** while the service stays up on the others
— so *mid-patch*, the nodes legitimately run different RUs. That's a transient state, not a resting one.
Here node1's home is on **19.27** and node2's is still on **19.26**: the DBA patched node1 and stopped.
Finish the job — apply 19.27 to node2's Oracle home so **all** nodes match — and only then run
`datapatch` **once** (from any node) to complete the SQL side (which is why the registry still shows
19.26). Leaving mixed-version homes running long-term is unsupported and risks node-specific bugs.
**The tell:** `opatch lspatches` differs **between nodes**.

## 06 — datapatch ran, but `STATUS = WITH ERRORS` → **not correctly patched; investigate the log and re-run `datapatch`**

The subtle one. There *is* a 19.27 row in `DBA_REGISTRY_SQLPATCH`, so at a glance the SQL side "ran" —
but the `STATUS` is **`WITH ERRORS`**, not `SUCCESS`. `datapatch` returning to the prompt means it
*finished*, not that it *succeeded*; some of the patch's SQL failed to apply (invalid objects, a blocked
component, a prior partial patch). The database is **not** fully patched. Read the `datapatch` log it
prints the path to, resolve the underlying cause, and **re-run `datapatch`** until the 19.27 row reads
`SUCCESS` (and objects recompile clean). **The tell:** don't stop at "there's a row" — read the `STATUS`
column.

---

### The reflex to build

Every time, verify **both stages and the status**:

```sql
select patch_id, action, status, description
from   dba_registry_sqlpatch
order  by action_time;
```

Then ask: does the newest SQL-patch row **match the binary home** (`opatch lspatches`), is its `STATUS`
**SUCCESS**, on RAC do **all nodes agree**, and is the RU actually **current**? "OPatch succeeded" is the
start of that checklist, never the end of it.

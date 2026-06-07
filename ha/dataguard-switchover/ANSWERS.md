# Answer Key

Spoilers. Try `exercises.md` first.

---

## Scenario 01 — Switchover
- **Action:** **Switchover** — the primary is healthy and reachable, and this is planned work.
- **Command:** `DGMGRL> SWITCHOVER TO 'prod_sby';`
- **Old primary:** becomes the new **standby**, stays in the configuration. Fully **reversible** — switch
  back after the patch.
- **Data loss:** **none.** A switchover is a graceful hand-off; the primary ships its final redo first.
- **The tell:** Configuration `SUCCESS`, both databases up, standby `Transport Lag: 0 / Apply Lag: 0` —
  a healthy, synchronized pair, so the clean role reversal is available.

## Scenario 02 — Manual failover
- **Action:** **Failover** — the primary host is gone and unreachable, so there is nothing to hand off
  to; you can't switchover a dead primary. FSFO is disabled, so you do it by hand.
- **Command:** `DGMGRL> FAILOVER TO 'prod_sby';`
- **Old primary:** drops out of the configuration. When the host is repaired, **reinstate** it with
  `REINSTATE DATABASE 'prod_pri';` (needs Flashback Database) — otherwise rebuild it from backup.
- **Data loss:** **zero (or near-zero).** Protection mode is **MaxAvailability (SYNC)** and the standby
  was synchronized (`Apply Lag: 0` at last status) — synchronous transport means committed redo was
  acknowledged by the standby before the primary confirmed the commit.
- **The tell:** `ORA-12543: TNS:destination host unreachable` + `DGM-17016: failed to retrieve status`
  for prod_pri, while prod_sby is `SUCCESS`. Primary gone → failover.

## Scenario 03 — Reinstate (FSFO already failed over)
- **What happened:** The **Observer** on `obs-host3` detected the primary loss and **failed over
  automatically** at 03:11. **`prod_sby` is now the PRIMARY.** You do **not** run a failover — it's done.
- **Outstanding action:** **Reinstate the old primary.** `prod_pri` is back but marked
  `ORA-16661: the standby database needs to be reinstated`. Run `REINSTATE DATABASE 'prod_pri';` (or, since
  `Auto-reinstate: TRUE`, FSFO will reinstate it once the Observer reconnects). After reinstatement
  prod_pri becomes a standby of the new primary prod_sby, clearing the `ORA-16817 unsynchronized` warning.
- **The tell:** in `SHOW CONFIGURATION`, **`prod_sby - Primary database`** and `prod_pri - Physical
  standby database (disabled)` with `ORA-16661 ... needs to be reinstated`; `Fast-Start Failover: ENABLED`
  with an Observer present.

## Scenario 04 — Quantifying failover data loss
- **Roughly how much:** about **the transport lag — ~14 seconds of redo** — is lost. In **MaxPerformance
  (ASYNC)** there is **no zero-data-loss guarantee**: redo is shipped asynchronously, so anything not yet
  *received* by the standby when the primary died is gone.
- **Which lag is the loss:** **transport lag** (redo not yet *received*) is the data-loss exposure.
  **Apply lag** (22s) is staleness / recovery time — redo received but not yet applied; it does **not**
  add to data loss (that redo is safe on the standby and will be applied during failover).
- **What would make it zero:** **synchronous transport** — MaxAvailability or MaxProtection — so a commit
  isn't acknowledged until the redo is on the standby.
- **The tell:** `Protection Mode: MaxPerformance` + `Transport Lag: 14 seconds`. Don't be fooled into
  quoting the 22s apply lag as data loss.

## Scenario 05 — Neither yet: fix the standby first
- **Action:** **Neither** — and this is **not** a failover situation (the primary is healthy). The
  **switchover was correctly refused** because the standby hasn't applied all its redo.
- **Why it failed:** `Transport Lag: 0` (redo is arriving) but `Apply Lag: 11m40s` with a low apply rate —
  the standby is **behind on apply**. A switchover requires the standby to be caught up so it can take
  over with no loss; Data Guard won't let you switch to a standby that isn't ready.
- **Fix before retrying:** get **Redo Apply** running and keep up — investigate the slow apply rate (I/O
  or CPU on the standby, or `MRP` not running / a gap), let apply lag drain to ~0, then retry the
  switchover. (For a redo *gap* variant — `ORA-16775` — let the Broker/FAL resolve it or ship the missing
  sequences.)
- **The tell:** `ORA-16470: ... standby has not applied all received redo` and `ORA-16853: apply lag has
  exceeded specified threshold`, with the **primary still healthy** ("primary database is still prod_pri").

---

### The meta-lesson
The one-sentence test (is the primary healthy + reachable?) sorts switchover from failover. Protection
mode + **transport lag** tells you the failover data loss — **not** apply lag. And a switchover has a
precondition the standby must meet: it has to have applied its redo. Confusing any of these under
pressure is how a routine maintenance window becomes a data-loss incident.

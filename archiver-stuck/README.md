# Archiver-stuck lab — reproduce ORA-00257, then clear it

Companion to [ORA-00257: The Database Stopped Accepting Writes. The Archiver Is
Stuck.](https://uptimearchitect.com/blog/oracle-ora-00257-archiver-stuck/).

`ORA-00257: archiver error. Connect internal only, until freed.` is the error users hit when an ARCHIVELOG-mode
database can no longer archive its redo. Almost always the cause is mundane: the archive destination — usually
the **Fast Recovery Area (FRA)** — is full because nobody backs up and removes the archived logs. Once the FRA
fills, the archiver (ARCn) can't write the next archived redo log, the online redo logs fill up and can't be
reused, and the instance refuses new redo. SYSDBA can still connect; everyone else is locked out. This lab forces
exactly that on a deliberately tiny FRA, then clears it the way you would at 3am — and proves normal writes resume.

## What it proves

| step | what happens |
| --- | --- |
| **fill a 50 MB FRA with archived redo** | archive destination 1 goes to **ERROR** (`ORA-19809`, "Stuck archiver condition declared" in the alert log) |
| **a normal (non-SYSDBA) user tries to write** | refused immediately with **ORA-00257** — while SYSDBA still connects fine |
| **RMAN backs up the archived logs outside the FRA + deletes the inputs, then the FRA is grown** | destination 1 returns to **VALID** and the same user connects and writes again |

The database is put in ARCHIVELOG mode with archiving pointed at a dedicated 50 MB FRA. A little redo plus a couple
of log switches fill it; the archiver's destination fails; a background "application" session then floods redo and
blocks on a log switch it can't complete, driving the online logs to full-and-unarchived. At that point a normal
user connecting is refused with ORA-00257. The fix backs the archived logs up to a location **outside** the FRA and
deletes the inputs (so they stop piling up), grows the FRA for headroom, and lets the archiver catch up — then the
same user writes successfully. If the outage doesn't reproduce, or the fix doesn't clear it, the run fails.

## Run it

```bash
./run.sh up        # start Oracle Database Free (first run pulls the image)
./run.sh all       # setup -> reproduce -> fix
```

```bash
./run.sh setup     # ARCHIVELOG + a dedicated 50 MB FRA + a redo-generating schema
./run.sh reproduce # fill the FRA until the archiver sticks; assert ORA-00257 for a normal user
./run.sh fix       # RMAN backup+delete of archived logs + headroom; assert writes resume
./run.sh sql       # SQL*Plus as SYSDBA
```

## Notes

- **ORA-00257 is a symptom; ORA-19809 is the cause.** What the user sees is "archiver error, connect internal
  only" (in 26ai the message reads *Connect AS SYSDBA only until resolved*). What the alert log and
  `V$ARCHIVE_DEST` show is `ORA-19809: limit exceeded for recovery files` — the archiver could not create the next
  archived log because the FRA is full. Diagnose from `V$RECOVERY_FILE_DEST` (space used vs limit),
  `V$RECOVERY_AREA_USAGE` (what's consuming it — almost always `ARCHIVED LOG`), and `V$ARCHIVE_DEST` (`STATUS` /
  `ERROR`).
- **SYSDBA is not affected; that's the escape hatch.** The whole point of "connect internal only" is that a
  privileged session can still get in to fix it. The lab proves this: the `arc` user is refused while `/ as sysdba`
  keeps working.
- **The real fix is backup + delete, not just `delete`.** Freeing space by deleting archived logs unsticks the
  database, but deleting logs you haven't backed up breaks your recovery window. The lab does it the right way:
  RMAN `BACKUP ARCHIVELOG ALL ... DELETE ALL INPUT` to a location outside the FRA, so the logs are safe *and* the
  space is reclaimed. Growing `db_recovery_file_dest_size` is the emergency lever that buys time; on its own it
  only delays the next fill.
- **Why the online redo logs matter.** With archiving dead, each online redo log becomes full-and-unarchived and
  can't be reused. The instance can't allocate redo space, so it blocks writers (SYSDBA waits; everyone else gets
  ORA-00257). This lab uses the image's two 20 MB online logs as-is — small enough that a single burst of redo
  exhausts them once the FRA is full.
- **The knobs are tuned to be deterministic:** a 50 MB FRA holds about two 20 MB archived logs, so a couple of
  switches fill it; the background flood is a single bounded insert so that, once the fix unblocks it, it finishes
  quickly instead of re-filling the FRA. Demo data is generic and invented.

## Cleanup

```bash
./run.sh down     # stop the container, keep the data volume
./run.sh destroy  # remove everything including the volume
```

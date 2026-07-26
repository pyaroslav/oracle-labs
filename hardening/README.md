# Hardening-audit lab — the checklist as a test

Companion to [The Oracle Hardening Checklist That Actually
Matters](https://uptimearchitect.com/blog/oracle-database-hardening-checklist/).

The blog post argues you should skip the two-hundred-item benchmark and do the handful of controls that
actually stop incidents. This lab makes that concrete: it stands up an Oracle Database Free container in
a **deliberately weak state**, scores it against those controls, then hardens it and re-scores — so every
check visibly flips from **FAIL** to **PASS**. No Oracle client needed; everything runs in the container.

## The six checks

| # | Check | Weak state it detects | Hardening that fixes it |
| --- | --- | --- | --- |
| 1 | **Default-password account** | `demo/demo` logs in (password = username) | lock + expire the account |
| 2 | **Network packages to PUBLIC** | `EXECUTE` on `UTL_HTTP`/`UTL_TCP`/… granted to `PUBLIC` | revoke from `PUBLIC` |
| 3 | **ANY-privileges on app accounts** | `SELECT ANY TABLE` on a customer account | revoke the `%ANY%` grant |
| 4 | **DBA on an app account** | `DBA` role on a customer account | revoke the super-role |
| 5 | **Failed-login lockout** | `DEFAULT` profile `FAILED_LOGIN_ATTEMPTS = UNLIMITED` | finite lockout + password lifetime |
| 6 | **Unified-auditing baseline** | `ORA_SECURECONFIG` / `ORA_LOGON_FAILURES` disabled | re-enable both policies |

Check 1 is a **live login test** — the honest form of the default-password check ("does this password
actually work?"), not just a lookup. Checks 2–4 use `ORACLE_MAINTAINED = 'N'` so they flag *your*
accounts, not Oracle's own. The listener/network and TDE controls from the post aren't in the lab — they
need a listener rebuild or a keystore/wallet that a single throwaway container can't prove cleanly — so
they're covered in the post, not here.

## Run it

```bash
./run.sh up      # start the database (first run pulls the image)
./run.sh all     # weaken -> audit (must FAIL) -> harden -> audit (must PASS) -> summary
```

Or step by step:

```bash
./run.sh setup   # put the database into the weak state
./run.sh audit   # score it — prints the PASS/FAIL table
./run.sh harden  # apply the six controls
./run.sh audit   # score it again — everything now PASS
./run.sh sql     # SQL*Plus as SYSDBA, to poke at it yourself
```

## What you should see

```
================ AUDIT: the database as delivered (weak) ================
  --------------------------------------------------------------------
  default-password account (demo/demo)         FAIL  (logs in with password = username)
  network packages granted to PUBLIC           FAIL  (UTL_HTTP/TCP/SMTP/INADDR/FILE EXECUTE to PUBLIC)
  ANY-privileges on customer accounts          FAIL  (e.g. SELECT ANY TABLE on an app account)
  DBA / PDB_DBA on customer accounts           FAIL  (an app account holds a super-role)
  failed-login lockout (DEFAULT profile)       FAIL  (FAILED_LOGIN_ATTEMPTS = UNLIMITED)
  unified-auditing baseline                    FAIL  (ORA_SECURECONFIG / ORA_LOGON_FAILURES disabled)
  --------------------------------------------------------------------
  6 checks, 6 failed

===================== AUDIT: after hardening ============================
  ... every line now PASS ...
  6 checks, 0 failed

>> PASS: all six controls went FAIL -> PASS. The checklist isn't a claim, it's a test.
```

The run **fails loudly** if the weak state doesn't produce exactly six failures (the checks are broken)
or if hardening leaves any check failing (hardening is incomplete). The CI matrix runs the whole cycle
on every push, so the numbers in the post are backed by a test, not asserted.

## Cleanup

```bash
./run.sh down     # stop the container, keep the data volume
./run.sh destroy  # remove everything including the volume
```

# Password-rollover lab — ORA-01017 after a password change, and how to avoid it

Companion to [ORA-01017 After a Password Change: Rotate It With Zero
Downtime](https://uptimearchitect.com/blog/oracle-ora-01017-password-rollover/)

An application account's password is changed. Some app servers have the new one, some still have the old one
(a rolling config push, a secret that hasn't synced, a pool that reconnects later). The ones on the old password
get `ORA-01017: invalid credential or not authorized; logon denied`, and their retries lock the account, which
takes down the servers that already had the new password as well. Gradual password rollover
(`PASSWORD_ROLLOVER_TIME`, 19.12 and later) lets the old and the new password both work for a window you choose.
This lab builds both versions of the change on one Oracle Database Free container, and the traps around it.

## What it proves

| case | what you see | asserted |
| --- | --- | --- |
| **Change with no rollover** | old password: ORA-01017 x5, then ORA-28000; the **new** password: ORA-28000 too | all of it, plus `LOCKED(TIMED)`, and a connection opened before the change still works |
| **Change with a 1-day rollover** | `OPEN & IN ROLLOVER`; old and new both log in; 7 old-password logins against a limit of 5 failures | all of it |
| **Who is still on the old password** | unified audit `LOGON_INFO`: `VERIFIER=12C-OLD` vs `12C-NEW` | 7 old, 1 new |
| **A wrong password during rollover** | still ORA-01017, still counts, still locks the account (both passwords then get ORA-28000) | all of it |
| **Window limits** | 30 minutes or 61 days: ORA-02377 | both rejected (1 hour to 60 days) |
| **Rollover set after the change** | status stays `OPEN`; old password: ORA-01017 | both |
| **A second change inside the window** | the original and the latest work; the one in the middle gets ORA-01017 | all three |
| **End the window early** | `EXPIRE PASSWORD ROLLOVER PERIOD`: `OPEN`, old gets ORA-01017, new works | all of it, and an open old-password connection survives |

## Run it

```bash
./run.sh up        # start Oracle Database Free (first run pulls the image)
./run.sh all       # outage -> rollover -> late -> twice -> finish (each starts from setup), about a minute
```

```bash
./run.sh setup     # create APP_USER, profile APP_PROF and audit policy APP_LOGONS (resets the lab)
./run.sh outage    # password change with no rollover; ORA-01017 -> ORA-28000 for everyone
./run.sh rollover  # the same change with PASSWORD_ROLLOVER_TIME 1; who is still on the old password
./run.sh late      # rollover limit set after the change: too late for that change
./run.sh twice     # a second change during the window drops the middle password
./run.sh finish    # EXPIRE PASSWORD ROLLOVER PERIOD once every client has moved
./run.sh sql       # SQL*Plus as SYSDBA
./run.sh destroy   # remove the container and its volume
```

## Notes

- **The lab uses its own profile.** This image's `DEFAULT` profile has `FAILED_LOGIN_ATTEMPTS UNLIMITED`; a stock
  Oracle install has 10. `APP_PROF` sets 5 so the lockout is quick and deterministic.
- **Rollover is a profile limit, not an `ALTER USER` option.** `PASSWORD_ROLLOVER_TIME` is in days (`1/24` is one
  hour, the minimum; 60 is the maximum; 0 turns it off). The window starts at the password change, so set the limit
  first.
- **`OPEN & IN ROLLOVER` doesn't mean the old password works.** After a second change inside the window, the status
  is the same, but only the original and the latest password are valid.
- **Existing sessions are never affected.** A password change, or ending the rollover, only applies to new logins.
  That's why a missed app server fails later, when its pool reconnects, not when the password changes.
- **The `VERIFIER=...-OLD/-NEW` tag is only in the audit trail if logons are audited.** The lab creates a policy
  (`CREATE AUDIT POLICY app_logons ACTIONS LOGON`) for `APP_USER`. `ORA_LOGON_FAILURES` isn't enabled in this
  image's PDB, and it only records failures anyway.
- The lab drops and recreates `APP_USER` on every setup; audit queries count only rows since the user's creation
  or last password change, so reruns don't see earlier runs.

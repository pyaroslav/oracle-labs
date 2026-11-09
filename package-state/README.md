# Package-state lab — ORA-04068 after a deploy: which packages raise it, and how to deploy without it

Companion to [ORA-04068 After a Deploy: The Retry Works. The Package State Is
Gone.](https://uptimearchitect.com/blog/oracle-ora-04068-package-state-discarded/)

A release replaces a PL/SQL package, and right after it the application logs fill with `ORA-04068: existing state
of packages has been discarded`. One error per connection, then it stops. This lab creates a package with one
package-level variable, deploys a new version under a live session, and proves what happens: the call fails, the
retry works, and the variable is back to its initial value. Then it shows which packages and which changes raise
the error (including two that look harmless), what a connection pool sees, and two ways to deploy without it:
`PRAGMA SERIALLY_REUSABLE` and edition-based redefinition.

## What it proves

`APP.PRICING` has one package-level variable, a call counter. It stands in for any cached value: a config row, a
session flag, a lookup table loaded once. Each "user" session calls the package, waits for the deploy, then calls
it again.

| drill | case | asserted |
| --- | --- | --- |
| `error` | the release replaces `PRICING`'s body | the next call fails with `ORA-04068` / `ORA-04061` / `ORA-04065`; the call after it works and the counter is back to **1**; the session's uncommitted insert is still there |
| `collat` | the session also uses `AUDIT_CTX` (its own variable); only `AUDIT_CTX` is recompiled | `PRICING` keeps counting (1, 2, 3) until `AUDIT_CTX` raises `ORA-04068`; then `PRICING`, which the release never touched, is back to **1** too |
| `which` | no package variables, new body | no error, the new code at once |
| | no package variables, new spec (a function added) | the same |
| | only a literal constant (`constant number := 5`) | the same |
| | a constant set at load (`constant date := sysdate`) | `ORA-04068` |
| | one variable, `ALTER PACKAGE ... COMPILE BODY` with no code change | `ORA-04068` |
| | a `%ROWTYPE` package variable, then `ALTER TABLE ... ADD` a column | `ORA-04068` (the package is invalidated) |
| | a variable, but the package names its columns, then the same `ADD` | no error (the package stays `VALID`) |
| `pool` | 8 pooled sessions, 6 have called `PRICING`, one deploy | **6** calls fail, one per session that held state; the second round has **0** |
| `serial` | `PRAGMA SERIALLY_REUSABLE` | no error after the deploy and the new code at once, but the counter is 1 on every call; a call from SQL fails with `ORA-06534` |
| `edition` | the new body compiled in edition `REL2` | the live session in `ORA$BASE` never errors and keeps counting (1, 2, 3) on the old code; new sessions get the old code until `ALTER DATABASE DEFAULT EDITION = REL2`, then the new code |

## Run it

```bash
./run.sh up        # start Oracle Database Free (first run pulls the image)
./run.sh all       # error -> collat -> which -> pool -> serial -> edition (each starts from setup), under a minute
```

```bash
./run.sh setup     # reset: APP.ORDERS and APP.PRICING recreated, APP sessions killed, edition REL2 dropped
./run.sh error     # ORA-04068 after a deploy, and what the retry gives you
./run.sh collat    # one package's ORA-04068 resets every package in the session
./run.sh which     # which packages and changes raise it
./run.sh pool      # one deploy, one error per pooled session that held state
./run.sh serial    # PRAGMA SERIALLY_REUSABLE: no error, no state
./run.sh edition   # edition-based redefinition: deploy under live sessions
./run.sh sql       # SQL*Plus as SYSDBA
./run.sh down      # stop and remove the container
./run.sh destroy   # remove the container and its volume
```

## Notes

- **It's the state, not the change.** A session that has used a package holds an instance of its variables. When
  the package is recompiled for any reason, that instance can't be kept, and the next call tells the session so
  with `ORA-04068`. A package without variables has nothing to throw away, so it switches to the new code silently,
  even when its spec changes.
- **Sessions are released by a file, not a sleep.** Each "user" session runs its first calls, prints `READY`, and
  waits for `/tmp/deployed` inside the container; the deploy creates it. So every assertion is about order, not
  timing.
- **Editions are a one-way switch for a user.** `ALTER USER app ENABLE EDITIONS` can't be undone. The `edition`
  drill turns it on; `setup` drops the `REL2` edition and sets the default edition back to `ORA$BASE`, so the other
  drills run the same afterwards. A session that has just ended can keep an edition "in use" (`ORA-38805`) for a
  few seconds, so `setup` retries the drop.
- **`setup` kills leftover `APP` sessions** from earlier drills, so each drill starts clean.

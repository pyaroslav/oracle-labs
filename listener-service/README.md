# ORA-12514 lab — the database is up, the listener just doesn't know it

Companion to [ORA-12514: The Database Is Up. The Listener Just Doesn't Know
It.](https://uptimearchitect.com/blog/oracle-ora-12514-listener-service/)

`ORA-12514: TNS:listener does not currently know of service requested in connect descriptor` (on 23ai/26ai
clients: `Cannot connect to database. Service X is not registered with the listener at host ... port ...`) means
the listener **answered**. It's running, it's reachable, and it has no service by the name you asked for. The
database behind it may be perfectly healthy. This lab builds the four common ways that happens, on one Oracle
Database Free container, and the checks that tell them apart.

## What it proves

| case | what you see | asserted | fix |
| --- | --- | --- | --- |
| **Wrong name** — `FREEPDB` instead of `FREEPDB1` | ORA-12514; `FREEPDB1` connects fine | ORA-12514, and the listener log records the name the client asked for | fix the connect string |
| **Listener restarted** | ORA-12514 for **every** service, ~60 s, then it clears by itself | ORA-12514 right after the restart, then recovery once the database re-registers | `ALTER SYSTEM REGISTER` (connects at once) |
| **PDB restarted** — app service created with `DBMS_SERVICE`, never saved | PDB is `READ WRITE`, `FREEPDB1` connects, `orders_app` gets ORA-12514 | all three | start the service and `SAVE STATE` (survives the next PDB restart) |
| **Listener on a port the database doesn't know** (1522) | `The listener supports no services`; ORA-12514 | both | `LOCAL_LISTENER` lists every listener address |

And the neighbours, so you can tell which error you actually have:

| error | means |
| --- | --- |
| ORA-12154 | the **alias** wasn't found in `tnsnames.ora` — the client never reached a listener |
| ORA-12541 | **no listener** at that host and port |
| ORA-12505 | a **SID** the listener doesn't know — often a PDB name given as a SID (`host:1521:FREEPDB1` in JDBC) |
| ORA-12514 | the listener answered; it has **no service** by that name |
| ORA-12504 | no service name at all, and the listener has no default service |

## Run it

```bash
./run.sh up        # start Oracle Database Free (first run pulls the image)
./run.sh all       # setup -> name -> restart -> service -> port
```

```bash
./run.sh setup     # create the ORDERS_APP service (resets the lab; safe to rerun)
./run.sh name      # wrong service name; assert ORA-12514; listener log; the neighbouring errors
./run.sh restart   # restart the listener; assert the ORA-12514 window; ALTER SYSTEM REGISTER closes it
./run.sh service   # PDB restart drops the app service; assert ORA-12514; SAVE STATE fixes it
./run.sh port      # second listener on 1522; assert ORA-12514; LOCAL_LISTENER fixes it
./run.sh sql       # SQL*Plus as SYSDBA
./run.sh destroy   # remove the container and its volume
```

The restart drill waits for the database to re-register by itself, so `all` takes a minute longer than you'd
expect. That minute is the point.

## Notes

- **Restarting the listener is the usual first reaction, and it causes the problem.** A restarted listener knows
  no services until the database registers again (the LREG process, on its default interval, about a minute in
  this lab). `ALTER SYSTEM REGISTER` does it immediately. `lsnrctl reload` re-reads `listener.ora` without a
  stop/start, but on this listener it sometimes dropped every registration too (the run prints what it kept), so
  follow a reload with `ALTER SYSTEM REGISTER` as well.
- **The listener log shows what the client asked for.** Each refused connect is logged with the requested
  `SERVICE_NAME`, the client program and host, and `TNS-12514` with the classic text, even on 26ai. That's how
  you find the app with the typo.
- **`SAVE STATE` is the single-instance fix.** Under Grid Infrastructure or RAC, define the service with
  `srvctl add service -db ... -pdb ... -service ...` and Clusterware starts it with the database. With Data
  Guard, the same mechanism adds `-role PRIMARY` so the service starts only on the primary; the lab doesn't
  build that case.
- **`LOCAL_LISTENER` is set `scope=memory` in the lab** so a rerun starts clean. On a real system use
  `scope=both`. On a Grid node the agent manages `LOCAL_LISTENER`; don't hand-set it there.
- **No service name at all lands in `CDB$ROOT` here** only because this image's `listener.ora` sets
  `DEFAULT_SERVICE_LISTENER = FREE`. A listener without that parameter answers `ORA-12504`.
- The `SAVE STATE` in `setup` records FREEPDB1's state without the app service, so every run starts from the
  broken case.

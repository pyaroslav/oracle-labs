# Debezium CDC lab — Oracle to Kafka with the Debezium Oracle connector (LogMiner)

Companion to two posts:

- [Oracle to Kafka with Debezium: The Connector Says RUNNING. The Data Is
  Wrong.](https://uptimearchitect.com/blog/oracle-debezium-cdc-wrong-data/)
- [Debezium on Oracle: One Idle Transaction, One Log Purge, and a Connector That Can't
  Resume](https://uptimearchitect.com/blog/oracle-debezium-offset-scn-archived-logs/)

Three containers, all public images: Oracle Database Free (`gvenzl/oracle-free`, currently 26ai), a single-node Kafka
(`apache/kafka:4.3.1`, KRaft) and Kafka Connect with the Debezium Oracle connector
(`quay.io/debezium/connect:3.7.1.Final`). Connect uses the JSON converter with `schemas.enable=false`. Every drill
registers its own connector with the documented minimum configuration plus only the settings it names, takes the
initial snapshot, makes changes in Oracle and asserts what arrives in Kafka.

Setup puts the database in `ARCHIVELOG` mode with minimal supplemental logging, creates the connector's LogMiner user
`c##dbzuser` with the grants from the Debezium documentation, and creates three identical tables that differ only in
table-level supplemental logging: `APP.ORDERS` `(ALL) COLUMNS`, `APP.ORDERS_PK` `(PRIMARY KEY) COLUMNS`,
`APP.ORDERS_MIN` none. Columns: `ID NUMBER(10)` primary key, `CUSTOMER VARCHAR2(40) NOT NULL`, `AMOUNT NUMBER(10,2)`,
`QTY NUMBER`, `STATUS`, `NOTE CLOB`.

## What it proves

### Wrong data, no error

| drill | case | asserted |
| --- | --- | --- |
| `supplog` | `UPDATE ... SET status = 'PAID' WHERE id = 1` on each table | `ORDERS`: key 1, the full row. `ORDERS_PK`: key 1, `CUSTOMER` `''`, `AMOUNT` null. `ORDERS_MIN`: **key 0**, `CUSTOMER` `''`, `AMOUNT` null. The connector stays `RUNNING`; the only signal is Debezium's WARN per table in the Connect log |
| `lob` | `lob.enabled=false` (default): `UPDATE` a CLOB that had a value to 8,000 characters | **no event** (a later marker update arrives) |
| | `UPDATE` a null CLOB to 8,000 characters | an update with `NOTE` null |
| | `INSERT` with an 8,000-character CLOB | an insert with `NOTE` null |
| | `INSERT` with `'hello'` | an insert with `NOTE` null, then an update with `'hello'` |
| | `lob.enabled=true`: the same update, and an insert | one event each, all 8,000 characters |
| `placeholder` | an `UPDATE` that doesn't touch the CLOB, `lob.enabled` false and true | `after.NOTE` = `"__debezium_unavailable_value"` |
| `numbers` | `decimal.handling.mode=precise` (default) | `AMOUNT` 100.50 → `"J0I="` (base64 of 10050); `QTY` → `{"scale":0,"value":"Aw=="}` |
| | `decimal.handling.mode=string` | `"100.50"`, `"3"`, `"1234567.891"` |

### Restarts and archived logs

| drill | case | asserted |
| --- | --- | --- |
| `pinned` | a session updates a row and sits idle (`INACTIVE`) with the transaction open; 3 commits elsewhere | all delivered; offset `commit_scn` passes the transaction, offset `scn` stays below its `START_SCN`; it moves once the transaction ends |
| `purge` | the same, then RMAN `DELETE ARCHIVELOG ALL` | `RUNNING` right after; at the next log switch the task fails with `None of the log files contain offset SCN: <scn>`; a later commit isn't delivered; a restart fails with `no longer available on the server` |
| | `snapshot.mode=when_needed` | `RUNNING` again after a new snapshot: every row sent again as `op=r` |
| `safepurge` | the same, but delete only archived logs with `NEXT_CHANGE#` ≤ the offset `scn` | a restart resumes with no new snapshot; later changes arrive |
| `retention` | `log.mining.transaction.retention.ms=30000`, a 60-second transaction that **commits** | the row is in Oracle and never reaches Kafka; Debezium logs `is being abandoned` |
| `sysddl` | `ADD COLUMN` as the owner, then as a deploy account with `ALTER ANY TABLE` | the next inserts are delivered |
| | `ADD COLUMN` as `SYSTEM`; as `SYS` (new connector) | the next insert fails with `DmlParserException` and stops the task; a restart fails the same way; a new connector runs |
| | `SYS` again, with `log.mining.schema_changes.username.exclude.list` (default `SYS,SYSTEM`) set to another user | still fails the same way |

## Run it

```bash
./run.sh up          # start the three containers (first run pulls ~7 GB of images)
./run.sh all         # every drill, each from setup
```

```bash
./run.sh setup       # ARCHIVELOG, users, tables; empty Kafka + Connect (resets the lab; safe to rerun)
./run.sh supplog     # table-level supplemental logging: ALL vs PRIMARY KEY vs none
./run.sh lob         # large CLOBs with lob.enabled false, then true
./run.sh placeholder # an unchanged CLOB in an update event
./run.sh numbers     # NUMBER(10,2) and NUMBER on the wire, precise vs string
./run.sh pinned      # an idle open transaction holds the restart position back
./run.sh purge       # delete the archived logs: failure at the next log switch, recovery by re-snapshot
./run.sh safepurge   # delete only what is below the connector's offset scn: restart works
./run.sh retention   # transaction retention silently drops a committed long transaction
./run.sh sysddl      # DDL as the owner / a deploy account works; as SYSTEM or SYS it stops the connector
./run.sh sql         # SQL*Plus as SYSDBA
./run.sh down        # stop (keep data)   |   ./run.sh destroy  # stop and delete the volume
```

Set `LAB_PORT` to publish Oracle on a different host port (default 1521). The drills only use `docker exec`, plus
`python3` on the host to summarise the change events (`scripts/ev.py`).

## Notes

- The lab tests what Debezium writes to the topic. It doesn't cover the XStream or OpenLogReplicator adapters, Avro
  or a schema registry, a particular sink connector, RAC, or a standby that also needs the archived logs.
- `ARCHIVELOG` mode and the purges only touch the lab's own database volume.

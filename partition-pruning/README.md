# Partition Pruning lab — read one partition, or all twenty-four

Companion to [Oracle Partition Pruning: Read One Partition, Not the Whole
Table](https://uptimearchitect.com/blog/oracle-partition-pruning/).

Partitioning only makes queries faster if the optimizer **prunes** — reads the partitions a query needs and
skips the rest. This lab proves pruning works, and proves how easily it's defeated. It builds a 1.2M-row
`ORDERS` table with one partition per month (24 months) and runs the **same** question — how many orders in
June 2025? — two ways:

- a **range predicate** on the partition key (`order_date >= DATE '2025-06-01' AND < '2025-07-01'`) → the
  optimizer prunes to **one** partition;
- a **function** on the same key (`TO_CHAR(order_date,'YYYY-MM') = '2025-06'`) → pruning is defeated and
  **every** partition is scanned.

Same 50,000 rows either way. The only difference is how much of the table Oracle had to read — and it's about
24×. No Oracle client needed; everything runs in the container.

## What it proves

| | Range predicate (prunes) | Function on the key (no pruning) |
| --- | --- | --- |
| Plan operation | `PARTITION RANGE SINGLE` | `PARTITION RANGE ALL` |
| Partitions read (Pstart/Pstop) | **19 / 19** — one partition | **1 / 1048575** — all of them |
| Rows returned | 50,000 | 50,000 |
| Buffer gets | **1,725** | **41,448** (~24×) |

The run **asserts** every cell: same row count both ways, `SINGLE` vs `ALL`, one partition vs many, and that
the pruned query reads at least 5× fewer buffers (it reads ~24×). If pruning stops working — a version
change, a bad predicate — the run fails. It's a test, not a claim.

> `Pstop = 1048575` on the full-scan plan is Oracle's sentinel for "the maximum possible partition" on an
> interval-partitioned table — it means *all* partitions, not that a million exist. `PARTITION RANGE ALL` is
> the operation that matters.

## Run it

```bash
./run.sh up      # start the database (first run pulls the image)
./run.sh all     # setup (build the partitioned table + 1.2M rows) -> prove (both plans + asserts)
```

Or step through it:

```bash
./run.sh setup   # build the monthly-partitioned ORDERS table, 1.2M rows, gather stats
./run.sh prove   # run both queries, print both plans, assert pruning cuts the work while the count matches
./run.sh sql     # SQL*Plus as SYSDBA -- poke at it yourself
```

## What you should see

```
   PRUNE: op=PARTITION RANGE SINGLE partitions 19..19  count=50000  buffers=1725
   FULL : op=PARTITION RANGE ALL    partitions 1..1048575  count=50000  buffers=41448
   -> same 50,000 rows; pruning read ~24x fewer buffers by skipping the other partitions.

>> PASS: a range predicate on the partition key prunes to one partition; a function on it scans them all.
```

## Try it yourself

Once it's up, `./run.sh sql` and watch the plan change with the predicate:

```sql
ALTER SESSION SET CONTAINER = FREEPDB1;
SET LINESIZE 200

-- prunes to one partition (Pstart = Pstop):
EXPLAIN PLAN FOR SELECT COUNT(*) FROM sales.orders
  WHERE order_date >= DATE '2025-06-01' AND order_date < DATE '2025-07-01';
SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY(format => 'BASIC +PARTITION'));

-- same rows, but the function defeats pruning (PARTITION RANGE ALL):
EXPLAIN PLAN FOR SELECT COUNT(*) FROM sales.orders
  WHERE TO_CHAR(order_date, 'YYYY-MM') = '2025-06';
SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY(format => 'BASIC +PARTITION'));
```

## Notes

- **Interval partitioning** (`INTERVAL (NUMTOYMINTERVAL(1,'MONTH'))`) auto-creates a partition per month as
  data arrives, so setup doesn't hand-write 24 partition clauses. The seed partition (< 2024) stays empty, so
  the table ends up with 25 partitions, 24 of them holding 50,000 rows each.
- **Partitioning is an Oracle option**, included in Oracle Database Free for development. The lab uses it out
  of the box.
- **`Pstart = KEY`** (not seen here because the lab uses literal dates) is *dynamic* pruning with bind
  variables — pruning working at run time, not a failure. `PARTITION RANGE ALL` is the failure.
- Demo data is generic and invented — nothing sensitive.

## Cleanup

```bash
./run.sh down     # stop the container, keep the data volume
./run.sh destroy  # remove everything including the volume
```

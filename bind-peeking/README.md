# Bind peeking lab — same SQL, fast for one value, slow for another

Companion to [Same SQL, Fast for One Value, Slow for
Another.](https://uptimearchitect.com/blog/oracle-bind-peeking-adaptive-cursor-sharing/).

When a statement with a bind variable is hard-parsed, Oracle **peeks** at the bind value and optimizes for it.
Every later execution of that cursor reuses the plan, whatever value it binds. On a skewed column that means the
first caller decides the plan for everyone. **Adaptive cursor sharing** (ACS) is supposed to notice and give
different values their own plans. This lab shows the peek going wrong, and shows ACS not catching it.

## What it proves

`ORDERS` has 200,000 rows with a skewed `STATUS`: **200 `OPEN`, 199,800 `CLOSED`**, and a frequency histogram on
the column. One statement joins it to a 1,000,000-row `CUSTOMERS` table:

```sql
select count(c.region) from acs.orders o join acs.customers c on c.cust_id = o.cust_id where o.status = :s
```

Measured as session logical reads from `V$MYSTAT`, one execution per fresh session, after a shared pool flush:

| execution | rows | logical reads | child cursor | plan |
| --- | --- | --- | --- | --- |
| `:s = 'OPEN'` (peeked first) | 200 | 2,624 | 0 | nested loops |
| **`:s = 'CLOSED'`, runs 1–5** | **199,800** | **603,354** each | **0** | **nested loops** |
| `'CLOSED'` as a literal (its own plan) | 199,800 | **34,716** | — | hash join |
| `'OPEN'` as a literal | 200 | 806 | — | nested loops |

The peeked `OPEN` plan probes `CUSTOMERS` once per order: right for 200 rows, **17× the work** of a hash join for
199,800. All five `CLOSED` runs reuse child cursor 0, and ACS never marks the cursor bind-aware. The run asserts
the nested-loops inheritance, the ≥10× penalty, that the cursor never splits, and that the per-value plan fixes it.
(Exact numbers can vary slightly by release; the ratios and plans are what the run checks.)

## Run it

```bash
./run.sh up       # start Oracle Database Free (first run pulls the image)
./run.sh all      # setup -> peek -> fix
```

```bash
./run.sh setup    # build the schema, gather stats with a histogram on STATUS
./run.sh peek     # flush, peek 'OPEN', then run 'CLOSED' five times on the inherited plan
./run.sh fix      # the predicate as a literal: one cursor and plan per value
./run.sh sql      # SQL*Plus as SYSDBA
```

## Notes

- **Why ACS didn't step in.** ACS sorts each execution of a bind-sensitive cursor into buckets by how much work it
  did (roughly: under 1,000, 1,000 to 1,000,000, over 1,000,000) and only splits the cursor once executions land
  in *different* buckets. The first `OPEN` execution (2,624 reads, including the hard parse) and every `CLOSED`
  execution (603,354) fell in the same middle bucket, so ACS saw nothing to react to. Inspect it with
  `V$SQL.IS_BIND_SENSITIVE / IS_BIND_AWARE` and `V$SQL_CS_HISTOGRAM`. With a different execution order (several
  cheap `OPEN` runs first) the cursor does become bind-aware and `CLOSED` gets a hash join; that is exactly the
  problem: whether you are protected depends on which values arrive first after every restart, flush, or stats
  refresh.
- **The literal fix is for skewed, low-cardinality columns only.** A status code with a handful of values makes a
  handful of cursors: no hard-parse storm. Keep binds for high-cardinality values such as IDs (see the
  [bind-variables lab](../bind-variables/)).
- **Other options.** A SQL plan baseline with more than one accepted plan (it cooperates with ACS), splitting the
  query by value in the application, or removing the histogram if one plan is genuinely good enough. Disabling
  bind peeking database-wide (`_optim_peek_user_binds`) is a hidden parameter: don't.
- **Adaptive plans don't save it either.** The peeked plan here is an adaptive plan with a statistics collector,
  but an adaptive plan resolves on its first execution and the resolved plan is reused. Demo data is generic and
  invented.

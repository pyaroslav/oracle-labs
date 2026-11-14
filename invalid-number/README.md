# Invalid-number lab — ORA-01722 that comes and goes with the plan, not the data

Companion to [ORA-01722 Invalid Number: The Bad Rows Were Always There. The Plan
Wasn't.](https://uptimearchitect.com/blog/oracle-ora-01722-invalid-number/)

A report that has run for months fails with `ORA-01722: invalid number`. Nobody changed the code, and nobody loaded
bad data: the rows that can't be converted were there all along. What changed is the plan. This lab keeps numbers
and text in one `VARCHAR2` column, runs the same report with the same data, and shows it working on one plan and
failing on another, how the plan gets picked, why the usual guards don't protect you, and the fixes that don't
depend on evaluation order. It also shows the decimal-separator variant, where the popular fix fails silently.

## What it proves

`APP.SENSORS` has 1,000 sensors: 900 `TEMP` sensors write numbers (`'150.5'`) and 100 `STATUS` sensors write text
(`'OK'`, `'ALARM'`, `'n/a'`) into the same `APP.READINGS.VAL` column (500,000 rows, 500 per sensor, index on
`SENSOR_ID`). Site `HQ` has 500 sensors; sites `S000`–`S099` have 5 each. Every statistics gather in the lab is
the same call, with frequency histograms on `SENSORS.SITE` and `SENSORS.KIND` and none elsewhere. The report counts
a site's `TEMP` readings above 150:

```sql
select count(*) from readings r join sensors s on s.sensor_id = r.sensor_id
where s.site = :site and s.kind = 'TEMP' and to_number(r.val) > 150;
```

| drill | case | asserted |
| --- | --- | --- |
| `day1` | after a hard parse, the first execution is a small site (`S007`) | the adaptive plan resolves to **NESTED LOOPS**; `S007` returns **495**, then `HQ` returns **54450** on the same cursor |
| `day2` | no data change; the same stats gather invalidates the cursor; the first execution is `HQ` | statistics identical before and after (rows, distinct values, histograms); the plan resolves to **HASH JOIN** (a different plan hash value); `HQ` fails with `ORA-01722`, and so do `S007` and `S042` on the same cursor |
| | the next gather; a small site runs first | **NESTED LOOPS** again, everything works: it "fixed itself" |
| `nohist` | the same day 2 with no histograms | `HQ` fails on the hash join and the cursor is marked reoptimizable; the next execution (`S007`) gets a new child cursor with **NESTED LOOPS** and works |
| `noindex` | no index on `READINGS.SENSOR_ID` | even the small site gets **HASH JOIN** and `ORA-01722` |
| `message` | what the error tells you | 26ai names the column (`VAL`) and the value (`ORA-03302 ... invalid string value: ALARM`); `VALIDATE_CONVERSION` finds 3 bad values in 50,000 rows, all from `STATUS` sensors |
| `guards` | the filter in an inline view, `TO_NUMBER` outside | `ORA-01722` |
| | the same view with `NO_MERGE` | `ORA-01722` (the view stays, the conversion is still applied in the scan) |
| | `VAL = 150` (no `TO_NUMBER` written) | `ORA-01722`: Oracle converts the column, not the literal |
| | `VAL = '150'` | works (a string compare) |
| `fix` | `TO_NUMBER(r.val DEFAULT NULL ON CONVERSION ERROR)`, `HQ` first | **54450** on the hash join |
| | `CASE WHEN s.kind = 'TEMP' THEN TO_NUMBER(r.val) END > 150`, `HQ` first | **54450** on the hash join (the conversion moves to the join, after the sensor filter) |
| `nls` | a session with `NLS_TERRITORY = GERMANY` (comma decimal separator), plain `TO_NUMBER` | `ORA-01722` on `'100.5'`, a `TEMP` value: no text row needed |
| | `DEFAULT NULL ON CONVERSION ERROR` in that session | no error, **26950** instead of 54450: the decimals became NULL |
| | an explicit `'NLS_NUMERIC_CHARACTERS = ''.,'''` | **54450** |
| | a virtual column with the explicit format | **54450** in both sessions |

## Run it

```bash
./run.sh up        # start Oracle Database Free (first run pulls the image)
./run.sh all       # day1 -> day2 -> nohist -> noindex -> message -> guards -> fix -> nls (each from setup), under a minute
```

```bash
./run.sh setup     # reset: APP.SENSORS and APP.READINGS recreated, shared pool flushed
./run.sh day1      # small site first: nested loops, both sites work
./run.sh day2      # same data, big site first: hash join, every site fails; day 3 it "fixes itself"
./run.sh nohist    # day 2 without histograms: one failure, then statistics feedback recovers
./run.sh noindex   # without the index, every site fails
./run.sh message   # what the 26ai message tells you, and finding the bad rows
./run.sh guards    # inline view, NO_MERGE, implicit conversion: none of them protect
./run.sh fix       # DEFAULT NULL ON CONVERSION ERROR, CASE: both work on the plan that failed
./run.sh nls       # comma decimal separator: an error, a silent wrong answer, and the explicit fix
./run.sh sql       # SQL*Plus as SYSDBA
./run.sh down      # stop and remove the container
./run.sh destroy   # remove the container and its volume
```

## Notes

- **The conversion runs where the plan puts it.** On a nested-loops plan, `READINGS` rows are fetched through the
  index for the sensors that passed `kind = 'TEMP'`, so `TO_NUMBER` only sees numbers. On a hash join, `READINGS` is
  scanned in full and the single-table filter `TO_NUMBER(r.val) > 150` is applied to every row in the scan, before
  the join has removed the `STATUS` sensors. Same SQL, same data, different set of rows reaching `TO_NUMBER`.
- **The first execution picks the plan.** The plan is adaptive: a statistics collector counts the sensors the site
  returns and picks nested loops or a hash join at run time, on the cursor's first execution. Later executions
  reuse that choice, whatever the site. In the lab the cursor kept the hash join through every failed execution.
- **Day 2 uses `NO_INVALIDATE => FALSE`** so the invalidation is immediate. With the default
  (`DBMS_STATS.AUTO_INVALIDATE`) the cursor is invalidated over a window after the gather, so in production the hard
  parse, and the plan choice, come some time later. A restart, a shared-pool flush, an index rebuild, or a cursor
  aged out of the shared pool does the same.
- **Why the hash join sticks: the estimate was right.** With the histogram on `SITE`, the optimizer estimated `HQ`'s
  sensors correctly, so nothing marked the cursor for reoptimization, and it kept the hash join through every
  failure. Without histograms (`nohist`) it estimated about 10 sensors for any site; `HQ` returned 450, the cursor
  was marked reoptimizable (statistics feedback) even though the execution failed, and the next execution got a
  new child cursor with nested loops. The same happens in the `fix` drill, where `HQ` completes: the next
  execution may run on a new child.
- **Identical statistics on purpose.** Each gather pins `METHOD_OPT`. With the default (`SIZE AUTO`), the first
  gather after the report has run would add histograms the earlier gather didn't have, and day 2 would differ
  from day 1 in more than the cursor.
- **The plan is read in the same session** with `DBMS_XPLAN.DISPLAY_CURSOR` of the last statement (`APP` has
  `SELECT` on the four `V$` views it needs), so the check doesn't depend on finding the cursor later.
- **Why `DEFAULT NULL ON CONVERSION ERROR` isn't the whole fix.** It removes the dependency on evaluation order, but
  it also turns every value it can't convert into NULL, including valid numbers in a format the session doesn't
  expect. Give it an explicit format and `NLS_NUMERIC_CHARACTERS`, or keep numbers in a `NUMBER` column.
- **Not shown:** a single-table query. With only `kind = 'TEMP' AND TO_NUMBER(val) > 150` on one table, 26ai put the
  cheap `kind` test first in the filter whatever the order in the text, so it didn't fail in this lab.
  Oracle doesn't guarantee that order either.
- The lab runs on the regular `gvenzl/oracle-free` image (Oracle Database Free, currently 26ai). Everything runs
  inside the container, so you only need Docker. If port 1521 is taken, set `LAB_PORT`.

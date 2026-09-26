# Character-set migration lab -- reproduce silent data loss, then prevent it

Companion to [The Migration Completed Successfully. Half the Names Are Now Question
Marks.](https://uptimearchitect.com/blog/oracle-character-set-migration-data-loss/).

The most dangerous Oracle migration is the one that reports success. When Unicode (AL32UTF8) data is loaded into
a database with a **narrower character set** -- US7ASCII, WE8MSWIN1252, and friends -- every character the target
set cannot represent is quietly transliterated or replaced with `?`. The import prints no error, the row counts
match, everyone signs off... and weeks later the support tickets arrive about `José` showing as `Jose` and a
customer's name rendered as `??`. This lab forces that loss on demand, shows the pre-migration scan that catches
it, and proves a Unicode target preserves everything.

## What it proves

A 10-row `customers` table in the AL32UTF8 database -- 5 plain-ASCII names and 5 with non-ASCII characters (Latin
accents and a CJK name) -- "migrated" into different target character sets with `CONVERT` (exactly what the
target database's conversion does on import):

| target character set | result |
| --- | --- |
| **US7ASCII** | 10 rows, no error -- but **5 of 10 names damaged**: accents silently stripped (`José`->`Jose`, `François`->`Francois`) and the CJK name turned into `??` |
| **WE8MSWIN1252** (Western European) | Latin accents survive, but the **CJK name is still lost** (`??`) |
| **AL32UTF8** (Unicode) | **zero loss** -- a superset represents every character |

The row count never changes and no error is ever raised, which is why this passes every naive migration check. A
round-trip test (`CONVERT` to the target and back, compared to the original) is what actually detects it -- run
as a pre-migration scan, it flags exactly the 5 rows a US7ASCII target would damage. If the loss does not
reproduce, or the scan/Unicode target don't behave, the run fails.

## Run it

```bash
./run.sh up        # start Oracle Database Free (first run pulls the image)
./run.sh all       # setup -> reproduce -> fix
```

```bash
./run.sh setup     # build the customers table (5 ASCII + 5 non-ASCII names)
./run.sh reproduce # migrate to a narrow target charset; assert silent data loss
./run.sh fix       # scan for lossy rows + migrate to a Unicode target; assert zero loss
./run.sh sql       # SQL*Plus as SYSDBA (UTF-8 client)
```

## Notes

- **"Successful" is not "correct".** The load raising no error and the row counts matching are exactly the checks
  teams rely on -- and both pass while data is being destroyed. Character-set loss is invisible to row counts;
  you have to compare the *values*.
- **Two flavors of loss, one of them sneaky.** Unmappable characters become `?` (obvious once someone looks), but
  characters the target set can *approximately* represent are silently transliterated -- `José` becomes a
  perfectly plausible, perfectly wrong `Jose`. The plausible one is the one that survives QA.
- **The scan is a round-trip.** `CONVERT(CONVERT(name,'US7ASCII','AL32UTF8'),'AL32UTF8','US7ASCII') <> name`
  flags any row that would not survive the target set -- the same idea the Database Migration Assistant for
  Unicode (DMU), and the legacy `csscan`, implement for real. Run it *before* cutover.
- **A Unicode target is the fix.** AL32UTF8 is a superset of every legacy character set, so migrating *into* it
  loses nothing. The trap is migrating the other way, or through a mismatched client `NLS_LANG` -- see the post.
- **The data is built from code points, not bytes.** The names are created server-side with `UNISTR('\00E9')`
  etc., so the script files are pure ASCII and portable -- the multibyte data is generated in the database, not
  carried in the file. Demo data is generic and invented.

## Cleanup

```bash
./run.sh down     # stop the container, keep the data volume
./run.sh destroy  # remove everything including the volume
```

# Data Redaction lab — mask at read time, then prove it isn't access control

Companion to [Oracle Data Redaction: Mask at Read Time, Prove It Isn't Access
Control](https://uptimearchitect.com/blog/oracle-data-redaction-mask-at-read-time/).

Data Redaction masks sensitive columns *as a query returns them*. It's easy to mistake for encryption or for
access control — it's neither. This lab builds one table of fake-but-sensitive rows (card number, SSN, email,
salary), protects it with a single `DBMS_REDACT` policy covering four columns with four different function
types, and then reads it back **as two different users** to show what redaction is and isn't:

- an ordinary **`CLERK`**, subject to the policy, sees masked values;
- an **`AUDITOR`** holding `EXEMPT REDACTION POLICY` sees the real values — proving the stored data is intact
  and redaction is decided per session, at read time.

Then it reads the raw datafile off disk and finds the real card numbers **still there**, and shows a `WHERE`
clause on the true card value **still matching** — the two facts that make the point: redaction is a display
control, not encryption at rest and not access control. No Oracle client needed — everything runs in the
container.

## What it proves

| Check | `CLERK` (subject to policy) | `AUDITOR` (`EXEMPT REDACTION POLICY`) |
| --- | --- | --- |
| `card` (PARTIAL, CCN-16) | `****-****-****-0001` | `4111-2222-3333-0001` |
| `ssn` (PARTIAL, US-SSN) | `XXX-XX-0001` | `123-45-0001` |
| `email` (REGEXP) | `xxxx@example.com` | `user0001@example.com` |
| `salary` (FULL) | `0` | `50001` |
| real card prefix on disk (`grep` the `.dbf`) | **present — 160+ hits** (redaction doesn't touch disk) | — |
| `WHERE card = '4111-2222-3333-0001'` as clerk | **matches (1 row)** — predicate sees the true value | — |

Same 2,000 rows, one policy. The run **asserts** every cell above and fails if any is wrong — if the clerk
sees a real value, if the auditor sees a masked one, if the card prefix is *absent* from disk, or if the
inference probe doesn't match. It's a test, not a claim.

> **Redaction vs encryption — read the disk and the difference is obvious.** In the
> [TDE lab](https://github.com/pyaroslav/oracle-labs/tree/main/tde) the canary string is **absent** from the
> encrypted datafile (the bytes are ciphertext). Here the real card numbers are **present** in the datafile —
> redaction never touched what's on disk, it only changed what the query returned. They protect different
> threats: encryption defends the file; redaction narrows who sees full values on screen. Use both.

## Run it

```bash
./run.sh up      # start the database (first run pulls the image)
./run.sh all     # setup -> prove (clerk masked, auditor real) -> disk (real data still there)
```

Or step through it:

```bash
./run.sh setup   # build the table + the 4-column redaction policy + the clerk/auditor users
./run.sh prove   # read id=1 as CLERK (masked) and AUDITOR (real); assert both, plus the inference probe
./run.sh disk    # grep the datafile: the real card prefix is still on disk in the clear
./run.sh clerk   # SQL*Plus as the CLERK user -- watch the masking yourself
./run.sh sql     # SQL*Plus as SYSDBA
```

## What you should see

```
>> PROVE: masked for the clerk, plaintext for the exempt auditor
   column     CLERK (subject)          AUDITOR (exempt)
   card       ****-****-****-0001      4111-2222-3333-0001
   ssn        XXX-XX-0001              123-45-0001
   email      xxxx@example.com         user0001@example.com
   salary     0                        50001

>> DISK: what redaction does NOT do
   real card prefix '4111-2222-3333' in datafile (.../red_data.dbf): 162 hit(s)
   -> the real card numbers are sitting on disk in plaintext. Redaction masked the query, not the datafile.

>> PASS: redaction masks at read time per user; the stored data is intact and still on disk;
>>       and a predicate on the true value still matches -- redaction is display control, not access control.
```

## Try it yourself

Once it's up, `./run.sh clerk` and see the two gotchas first-hand:

```sql
-- you see masked values...
SELECT card, ssn, email, salary FROM redown.customers WHERE id = 1;
-- ...but a redacted column inside an EXPRESSION returns NULL (anti-bypass -- you can't wrap it to leak it):
SELECT 'card is: ' || card FROM redown.customers WHERE id = 1;   -- returns NULL
-- ...and yet a predicate on the TRUE value still finds the row (redaction masks output, not the filter):
SELECT COUNT(*) FROM redown.customers WHERE card = '4111-2222-3333-0001';   -- 1
```

## Notes

- **Redaction needs Advanced Security**, which is included in Oracle Database Free for development. `setup`
  fails fast with a clear message if `DBMS_REDACT` isn't available.
- **A redacted column used in an expression returns NULL**, by design — so this lab labels masked values with
  SQL\*Plus `NEW_VALUE` + `prompt` (client side) rather than `'CARD='||card` (which would nullify).
- **`EXEMPT REDACTION POLICY`** is the system privilege that bypasses *all* policies; grant it deliberately
  and audit who holds it. Redaction is also transparently bypassed for `SYS` and for Data Pump full exports —
  it protects the query result, not the underlying data.
- Demo data is generic and invented (fake `4111-2222-...` card numbers, `123-45-...` SSNs) — nothing sensitive.

## Cleanup

```bash
./run.sh down     # stop the container, keep the data volume
./run.sh destroy  # remove everything including the volume
```

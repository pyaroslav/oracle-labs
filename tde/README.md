# TDE lab — read the datafile off disk and watch encryption actually work

Companion to [Oracle Transparent Data Encryption: Prove the Datafile Is
Unreadable](https://uptimearchitect.com/blog/oracle-transparent-data-encryption-tde/).

"The data is encrypted at rest" is easy to say and rarely checked. This lab checks it the only way that
settles the argument: it writes the same rows into an **encrypted** tablespace and an **ordinary** one, then
reads the raw `.dbf` files straight off disk. The recognizable canary string is plainly visible in the
unencrypted datafile and completely absent from the encrypted one — exactly the "someone walked off with the
datafile (or a backup)" threat TDE exists to stop. Then it closes the keystore and shows the database itself
goes blind to the encrypted data until the wallet is reopened. No Oracle client needed — everything runs in
the container.

## What it proves

| Check | Encrypted tablespace (`TDE_ENC`) | Ordinary tablespace (`TDE_PLAIN`) |
| --- | --- | --- |
| `DBA_TABLESPACES.ENCRYPTED` | `YES` | `NO` |
| canary string found in the `.dbf` on disk | **0 hits** (ciphertext) | **133 hits** (plaintext) |
| read after the keystore is **closed** | **ORA-28365** (blocked) | still readable |
| read after the keystore is **reopened** | readable again | readable |

Same 2,000 rows in each tablespace, same fake card numbers. The only difference is one tablespace was
created `ENCRYPTION USING 'AES256'`. The run **asserts** every cell above and fails if any of them is wrong —
if the canary shows up in the encrypted datafile, or closing the wallet doesn't block the read, the lab
fails. It's a test, not a claim.

> **Why read the datafile directly?** TDE encrypts data in the datafiles and backups, *not* in the buffer
> cache, redo you've already applied, or query results — a logged-in user with privileges sees plaintext as
> normal. The threat model is the file itself being stolen (a lost disk, a copied backup, a snapshot). So the
> honest test is to bypass the database and grep the bytes on disk, which is exactly what this lab does.

## Run it

```bash
./run.sh up      # start the database (first run pulls the image)
./run.sh all     # setup -> prove (assert ciphertext on disk) -> wallet (assert close blocks, open restores)
```

Or step through it:

```bash
./run.sh setup   # configure the TDE keystore (one restart), build the encrypted + plain tablespaces + canary data
./run.sh prove   # read both datafiles off disk: canary visible in plain, absent in encrypted
./run.sh wallet  # close the keystore -> encrypted table unreadable (ORA-28365); reopen -> readable again
./run.sh sql     # SQL*Plus as SYSDBA -- poke at it yourself
```

## What you should see

```
>> PROVE: the datafile on disk
   TDE_ENC encrypted=YES   TDE_PLAIN encrypted=NO
   canary 'CANARY_TDE_7F3A9B2E1D' in PLAIN  datafile (.../tde_plain.dbf): 133 hit(s)
   canary 'CANARY_TDE_7F3A9B2E1D' in ENC    datafile (.../tde_enc.dbf): 0 hit(s)
   -> plaintext datafile leaks the data; encrypted datafile is unreadable ciphertext.

>> WALLET: what the keystore controls
   wallet CLOSED -> encrypted read: BLOCKED_-28365 | plaintext read: READABLE_2000
   wallet OPEN   -> encrypted read: READABLE_2000
   -> keystore closed = encrypted data unreadable even to the DB; plaintext unaffected; reopen restores it.

>> PASS: encrypted-at-rest proven on disk (canary absent from the .dbf), and the wallet gates access.
```

## Try it yourself

Once it's up, `./run.sh sql` and grep the datafiles the way the lab does:

```sql
ALTER SESSION SET CONTAINER = FREEPDB1;

-- confirm which tablespace is encrypted
SELECT tablespace_name, encrypted FROM dba_tablespaces WHERE tablespace_name LIKE 'TDE\_%' ESCAPE '\';

-- see the master key and keystore status
SELECT status, wallet_type FROM v$encryption_wallet;
```

```bash
# from the host, grep the raw datafiles inside the container (the image has no `strings`, so grep -a):
docker exec ora-tde-lab sh -c "grep -a -c CANARY_TDE /opt/oracle/oradata/FREE/FREEPDB1/tde_plain.dbf"  # >0
docker exec ora-tde-lab sh -c "grep -a -c CANARY_TDE /opt/oracle/oradata/FREE/FREEPDB1/tde_enc.dbf"    # 0
```

## Notes

- **One restart.** `WALLET_ROOT` is a static parameter, so `setup` sets it and bounces the instance once,
  then configures the FILE keystore, sets the master key, and builds the tablespaces — all online after that.
- **`strings` isn't in the image**, so the lab greps the binary datafile with `grep -a` (treat-as-text).
- **The keystore is a password keystore, not auto-login** — deliberately, so the wallet close/open drill can
  show the database losing and regaining access. In production you'd usually add a local auto-login keystore
  so the database opens the wallet itself on startup.
- Demo data is generic and invented (fake `4111-1111-...` card numbers) — nothing sensitive.

## Cleanup

```bash
./run.sh down     # stop the container, keep the data volume
./run.sh destroy  # remove everything including the volume
```

# SQL*Net encryption lab — read the wire, then make it unreadable

Companion to [Your Oracle Traffic Is Readable on the Wire. Here's the Proof, and the
Fix.](https://uptimearchitect.com/blog/oracle-sqlnet-network-encryption/).

Out of the box, an Oracle client and server negotiate **no encryption**: both sides default to `ACCEPTED`, and
nobody asks. So every SQL statement and every row it returns crosses the network as readable bytes. This lab
proves it with a packet capture, then turns on native network encryption and integrity and proves the same
session is unreadable.

## What it proves

The same TCP session — the `APP` user connects to `//localhost:1521/FREEPDB1` and reads a confidential row
(`CANARY-7731-CONFIDENTIAL`) — captured with `tcpdump` twice:

| server `sqlnet.ora` | negotiated | SQL text in the capture | secret value in the capture |
| --- | --- | --- | --- |
| **default** (no encryption settings) | `NONE` / `NONE` | **readable** | **readable** |
| `SQLNET.ENCRYPTION_SERVER = REQUIRED` (AES256) + `SQLNET.CRYPTO_CHECKSUM_SERVER = REQUIRED` (SHA256) | `AES256` / `SHA256` | not found | not found |

The capture comes from a throwaway `alpine` sidecar that shares the database container's network namespace and
runs `tcpdump` on port 1521 — the same view anyone on the network path (a compromised host, a mirrored switch
port, a cloud VPC flow you don't control) would have. The negotiated algorithms are read from
`V$SESSION_CONNECT_INFO` inside the session itself. If the secret isn't readable on the default config, or is
still readable after the fix, the run fails.

## Run it

```bash
./run.sh up       # start Oracle Database Free (first run pulls the image)
./run.sh all      # setup -> sniff -> fix
```

```bash
./run.sh setup    # create the APP user + confidential table; reset sqlnet.ora to the default
./run.sh sniff    # capture the session on the default config; assert the secret is readable
./run.sh fix      # require AES256 + SHA256 on the server; capture again; assert nothing is readable
./run.sh sql      # SQL*Plus as SYSDBA
```

The raw captures are kept in `captures/plaintext.txt` and `captures/encrypted.txt` (`tcpdump -A`, git-ignored)
so you can read the wire yourself.

## Notes

- **The password is not the problem; everything after it is.** Oracle's logon is a challenge-response, so the
  password itself does not cross in the clear even on the default config. The SQL, bind values and result sets
  do.
- **`REQUIRED` on the server is the switch that matters.** With `ACCEPTED` (the default) on both ends, nobody
  requests encryption, so none happens. Setting the *server* to `REQUIRED` forces every new session to negotiate
  it — no client change needed, because clients default to `ACCEPTED`. A client that is configured `REJECTED`
  is refused (`ORA-12660`) instead of falling back to plaintext.
- **Integrity is a separate setting.** `CRYPTO_CHECKSUM` adds a per-packet SHA-2 MAC so traffic can't be tampered
  with or replayed in transit. Turn on both.
- **New sessions only, no restart.** The server reads `sqlnet.ora` when it spawns a dedicated server process for
  a new connection; existing sessions keep what they negotiated. Connection pools need recycling to pick it up.
- **Not everything is hidden.** The initial connect packet (service name, client program, OS user) is sent before
  negotiation and stays readable; the database username, SQL and data do not. If the connect descriptor itself
  is sensitive, use TLS (TCPS) instead.
- **Native encryption vs TLS.** Native network encryption needs no certificates and is a few lines of config;
  TLS (TCPS) adds server authentication via certificates (protecting against a rogue listener) and is what many
  compliance regimes name explicitly. Both are included in all editions. Demo data is generic and invented.

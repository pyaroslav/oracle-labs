# Idle-connection-drop lab — ORA-03113 / ORA-03135 after a connection sits idle behind a firewall

Companion to [ORA-03113 After the Connection Sat Idle: The Firewall Forgot
It](https://uptimearchitect.com/blog/oracle-ora-03113-idle-connection-firewall/)

A connection pool keeps sessions open between requests. Between the application and the database there is a
stateful device: a firewall, a NAT gateway, a cloud load balancer. It tracks every TCP connection, and forgets the
ones that stay idle longer than its timeout (4 minutes by default on an Azure Load Balancer, 350 seconds on an AWS
Network Load Balancer). The next time the pool uses that connection, the query fails with
`ORA-03135: connection lost contact`, or hangs for many minutes and then fails with
`ORA-03113: end-of-file on communication channel`. Nothing is wrong with the database, and its alert log shows
nothing. This lab puts that firewall between a client and an Oracle Database Free container and proves the errors,
the fixes, and the traps around them.

## What it proves

The lab's firewall forgets a connection after **90 seconds** idle. Each client runs a query, sits idle **110
seconds**, then runs a second query.

| case | second query | asserted |
| --- | --- | --- |
| **Firewall sends a TCP reset** (AWS NLB; Azure LB with TCP reset on idle) | ORA-03135 at once | the error, and that the database still has the session |
| **Firewall drops silently** (Azure Load Balancer's default), client TCP retries cut to 5 | no answer, then ORA-03113 after ~14 s | the error, and that the database still has the session |
| **Same, Linux default retries (15)** | no answer, then ORA-03113 after ~16 minutes | measured once by hand (951 s), not in `all` |
| **Same, `SQLNET.RECV_TIMEOUT = 30` in the client's `sqlnet.ora`** | ORA-12609 after ~61 s | the error |
| **`SQLNET.EXPIRE_TIME = 1` in the server's `sqlnet.ora`** | works | keepalive at 60 s refreshes the firewall's 90 s timer |
| **`SQLNET.EXPIRE_TIME = 2`** | fails anyway | 120 s is over the 90 s timeout |
| **`(ENABLE=BROKEN)` in the connect descriptor** | fails anyway | the OS default keepalive time is 2 hours |
| **`(ENABLE=BROKEN)` + `net.ipv4.tcp_keepalive_time = 60` on the client host** | works | |
| **`SQLNET.EXPIRE_TIME = 1` in the client's `sqlnet.ora`** (the lab's client is 26ai) | works | |
| **Client host disappears**, no `EXPIRE_TIME` | session still there after 240 s | |
| **Client host disappears**, `EXPIRE_TIME = 1` | session removed after ~117 s | |

## How the firewall works

There is no separate firewall box. The database container's network namespace gets two kernel settings in
`docker-compose.yml`:

- `net.netfilter.nf_conntrack_tcp_timeout_established = 90`: connection tracking forgets an idle TCP flow after
  90 seconds, the way a firewall's state table does.
- `net.netfilter.nf_conntrack_tcp_loose = 0`: once forgotten, a flow isn't picked up again from the middle.

`run.sh` then starts a small sidecar container that shares the database's network namespace and adds one iptables
rule for port 1521: packets of a forgotten (`INVALID`) flow are dropped, or answered with a TCP reset. The rule
filters only what arrives at the database, so a reset goes to the client and never to the database: the same
thing an Azure NAT gateway does (its reset is one-way), and what any middlebox does when it simply drops.
Clients run in their own containers on the lab network, so the "firewall" is between them and the database.

## Run it

```bash
./run.sh up        # start Oracle Database Free (first run pulls the image)
./run.sh all       # reset -> drop -> fix -> toolate -> client -> dead (each starts from setup), about 16 minutes
```

```bash
./run.sh setup     # reset: no EXPIRE_TIME, firewall in drop mode, leftover APP sessions killed
./run.sh reset     # the firewall sends a reset: ORA-03135
./run.sh drop      # the firewall drops silently: ORA-03113 (TCP retries 5) and ORA-12609 (RECV_TIMEOUT 30)
./run.sh fix       # SQLNET.EXPIRE_TIME = 1: the session survives
./run.sh toolate   # SQLNET.EXPIRE_TIME = 2: it doesn't
./run.sh client    # ENABLE=BROKEN alone, + a 60 s OS keepalive time, and client-side EXPIRE_TIME
./run.sh dead      # a vanished client: kept without EXPIRE_TIME, removed with it
./run.sh sql       # SQL*Plus as SYSDBA
./run.sh down      # stop and remove the container (and the firewall sidecar and any leftover clients)
./run.sh destroy   # remove the container and its volume
```

## Notes

- **The drills take time on purpose.** Every client has to sit idle longer than the firewall timeout, so each drill
  takes about two minutes. The 90 s timeout is the shortest that still lets `EXPIRE_TIME = 1` (60 s) fit under it.
- **`SQLNET.EXPIRE_TIME` is in minutes and goes in the server's `sqlnet.ora`.** Where the OS supports it, Oracle
  Net uses it to tune TCP keepalive on the server side of each new connection. Server processes read `sqlnet.ora`
  when they start, so it applies to new connections only; existing ones keep what they had.
- **Pick it from the timeout, not from habit.** It must be below the smallest idle timeout on the path. With
  Azure's 4-minute default, `EXPIRE_TIME = 10` does nothing.
- **The silent case is the slow one.** With no reset, the client keeps retransmitting until TCP gives up:
  `net.ipv4.tcp_retries2 = 15` by default on Linux, about 16 minutes in the lab. The lab cuts it to 5 so `all`
  finishes; it doesn't change which error you get.
- **`docker kill` is not a dead host.** Killing the client process lets its kernel close the connection, and the
  database notices at once. The `dead` drill disconnects the client's network instead, so nothing is closed.
- **The orphans are real.** In the reset and drop drills, the database keeps the client's session as `INACTIVE`
  after the client has given up. Without `EXPIRE_TIME`, nothing ever removes it. In a real system such a session
  can hold locks and counts against `SESSIONS` and `PROCESSES`.
- **`setup` kills leftover `APP` sessions** from earlier drills, so each drill starts clean.

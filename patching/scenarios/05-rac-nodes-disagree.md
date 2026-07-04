# Scenario 05 — A two-node RAC, mid-patch

A two-node **RAC** database on **19c**. The patching window was supposed to apply RU **19.27** in a
*rolling* fashion — one node at a time, service staying up. The DBA who ran it went home. You come in to
verify and check `opatch lspatches` on **each node's** Oracle home.

**Node 1:**
```console
[node1]$ $ORACLE_HOME/OPatch/opatch lspatches
37641958;Database Release Update : 19.27.0.0.250415 (37641958)
37642901;OCW Release Update : 19.27.0.0.250415 (37642901)

OPatch succeeded.
```

**Node 2:**
```console
[node2]$ $ORACLE_HOME/OPatch/opatch lspatches
36912597;Database Release Update : 19.26.0.0.250121 (36912597)
36878697;OCW Release Update : 19.26.0.0.250121 (36878697)

OPatch succeeded.
```

The database is open and serving on both nodes. The SQL registry still shows **19.26** as the newest
applied RU.

---

**Your call: what state is this in, and what do you do next?**

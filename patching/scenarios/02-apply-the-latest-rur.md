# Scenario 02 — "Apply the latest RUR to stay conservative"

Change review for a risk-averse production **19c** database. The inherited runbook says:

> *"Do not apply Release Updates — they contain functional and optimizer changes. Apply the latest
> **Release Update Revision (RUR)** each quarter instead: security fixes only, no behavior changes."*

The current level:
```sql
SQL> select version_full from v$instance;

VERSION_FULL
-----------------
19.24.0.0.0
```

A junior DBA asks you to find and download "the latest 19.24 RUR" from My Oracle Support so they can
follow the runbook. You go looking.

---

**Your call: what do you tell them — and what should the runbook say instead?**

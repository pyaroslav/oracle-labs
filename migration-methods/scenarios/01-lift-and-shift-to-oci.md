# Scenario 01 — Lift-and-shift to OCI

**Source**
- Oracle Database **19c Enterprise Edition**, single instance
- **Linux x86-64**, on-premises
- **8 TB**, OLTP, `ARCHIVELOG` mode, character set AL32UTF8

**Target**
- **OCI Exadata Database Service** (Linux x86-64), staying on **19c**

**Constraints**
- RTO for cutover: **under 30 minutes** (this is a 24×7 system)
- No version change, no character-set change, no platform/endian change
- You want a clean way to **fall back** if the cloud database misbehaves right after cutover

---

**Your call: which method, and why?**

# Scenario 04 — Oracle Database@Azure

**Source**
- Oracle Database **19c Enterprise Edition**, Linux x86-64, on-premises
- **5 TB**, 24×7

**Target**
- **Oracle Database@Azure** — Exadata Database Service, **19c**

**Constraints**
- RTO for cutover: **near-zero** (minutes)
- Same endian, same version, same character set
- A colleague insists: *"It's a different cloud — Azure — so you can't use Oracle's physical
  replication. You'll have to export with Data Pump and import."*

---

**Your call: is the colleague right? Which method, and why?**

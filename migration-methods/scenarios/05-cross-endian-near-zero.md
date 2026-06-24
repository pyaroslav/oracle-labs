# Scenario 05 — Cross-endian, near-zero, with a fallback

**Source**
- Oracle Database **11.2.0.4 Enterprise Edition**
- **AIX** (IBM Power, big-endian)
- **20 TB**, mission-critical, very high transaction rate

**Target**
- **OCI Exadata Database Service** — **Linux x86-64**, running **23ai/26ai**
  (so this is a **big version jump** *and* a **cross-endian** move)

**Constraints**
- RTO for cutover: **minutes** (near-zero downtime is mandatory)
- Budget for a **GoldenGate** license is approved
- The business demands a **fallback plan**: if the new primary misbehaves after cutover, you must
  be able to revert to the original with no data loss

---

**Your call: which method, and why?**

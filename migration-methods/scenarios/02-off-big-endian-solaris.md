# Scenario 02 — Off the old big-endian box

**Source**
- Oracle Database **19c Enterprise Edition**
- **Solaris SPARC** (big-endian)
- **12 TB**, mostly large historical tables

**Target**
- **OCI Exadata Database Service** — **Linux x86-64** (little-endian)

**Constraints**
- You have a **planned maintenance weekend** — a multi-hour outage is acceptable
- **No GoldenGate license** and no budget to buy one
- 12 TB is **too large** to export/import with Data Pump inside the weekend window
- Enterprise Edition on both ends

*Hint: run `SELECT platform_name, endian_format FROM v$transportable_platform;` on both sides before you choose.*

---

**Your call: which method, and why?**

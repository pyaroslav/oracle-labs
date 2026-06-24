# Answer key — with reasoning

Each scenario has one *best* method. The decision always comes down to four gates, in this order:

1. **What does the target allow?** Autonomous = logical only (no SYSDBA/file access). Exadata / Base DB / Database@Azure = everything.
2. **Are you crossing endianness or version?** If yes, physical restore and Data Guard are out — you need a logical method (GoldenGate / Data Pump) or transportable tablespaces with `RMAN CONVERT`.
3. **What's the downtime budget?** Near-zero → Data Guard (same arch) or GoldenGate (any arch). Outage OK → Data Pump or RMAN/offline.
4. **Edition & licensing?** Data Guard needs Enterprise Edition. GoldenGate is separately licensed.

---

## 01 — Lift-and-shift to OCI → **Data Guard physical online (ZDM physical)**

Same endian (Linux→Linux), same version (19c→19c), Enterprise Edition, `ARCHIVELOG`. Build a physical standby in OCI (RMAN *restore from service* / active duplication), let redo apply catch it up while the source serves traffic, then **switch over** — cutover is seconds-to-minutes, comfortably under the 30-minute RTO. After switchover the old on-prem primary becomes a standby of the new one, so if the cloud database misbehaves you simply **switch back** with no data loss — the fallback they asked for. ZDM "physical online" automates the whole thing.
*Why not Data Pump?* An 8 TB logical export/import won't fit a 30-minute window.

## 02 — Off big-endian Solaris → **Cross-platform Transportable Tablespaces (XTTS) with `RMAN CONVERT`**

`V$TRANSPORTABLE_PLATFORM` shows Solaris SPARC = **big-endian**, Linux x86-64 = **little-endian** → cross-endian, which **rules out a straight RMAN restore and Data Guard** (block-identical = same endian only). 12 TB is too large for Data Pump in a weekend, and there's no GoldenGate license. **XTTS** copies the datafiles physically, rolls the target forward with **RMAN incremental backups** while the source stays online, and `RMAN CONVERT` flips the endianness on the destination — only the **final** increment needs the tablespaces read-only, so the weekend outage is short. Enterprise Edition (fine here).

## 03 — Into Autonomous Database → **Data Pump (logical), via Object Storage**

The junior DBA's RMAN idea is **impossible**: Autonomous has no SYSDBA and no file-system access, so it is **not an RMAN target** — you can't restore a backup or stand up a physical standby into it. The supported path is **logical**: Data Pump with dump files in Object Storage, run as **ADMIN** (never SYS), excluding ADB-managed objects (`cluster,indextype,db_link`). The source is WE8MSWIN1252 but **ADB is fixed at AL32UTF8**, so the character set must converge to Unicode — run the **Cloud Premigration Advisor Tool (CPAT)** first to catch expansion/truncation. (If near-zero downtime were required, you'd reach for GoldenGate instead — still logical.)

## 04 — Oracle Database@Azure → **Data Guard physical (ZDM); the colleague is wrong**

Oracle Database@Azure **is** Oracle Exadata Database Service — the *same* service as OCI ExaDB — running on Oracle-managed Exadata hardware physically inside Azure data centers. So it exposes the **full toolbox** (RMAN, Data Guard, transportable tablespaces, Data Pump, GoldenGate, ZDM), and you **can** build a physical standby from on-prem **into Azure** and switch over. Same endian/version + near-zero RTO → Data Guard is the natural fit. The "it's Azure, so logical-only" claim is the trap — that would be true for a managed PaaS database (Autonomous), not for Exadata-in-Azure. (Also don't confuse it with the older *"Oracle Database Service for Azure,"* which keeps the database in OCI and connects over the Azure interconnect.)

## 05 — Cross-endian, near-zero, with fallback → **GoldenGate (ZDM logical online)**

This crosses **both** endianness (AIX big-endian → Linux little-endian) **and** a large version jump (11.2.0.4 → 26ai), while demanding **near-zero** downtime **and** a fallback. Only GoldenGate satisfies all of that at once. Data Pump does the initial load; GoldenGate captures changes from the source redo and applies them to keep the target current; you cut over with a sub-minute drain + reconnect. **Bidirectional** replication keeps the original AIX primary up to date after cutover, giving the no-data-loss fallback the business requires. (XTTS could do the cross-endian move but not near-zero downtime; Data Guard can cross neither endian nor version.) The license cost and operational complexity are the price you accept for that capability.

## 06 — Standard Edition source → **Data Pump or offline RMAN restore (NOT Data Guard)**

The inherited plan is invalid: **Data Guard is an Enterprise Edition feature** — it doesn't exist on Standard Edition 2, so you can't "build a standby and switch over." SE2 also can't use the free ZDM-physical-online (Data Guard) path. Your options are **outage** methods: **Data Pump** (logical) or an **offline RMAN backup/restore** (ZDM physical *offline*). Minimize the window with parallelism and a fast network/restore, but accept that near-zero downtime isn't available without Enterprise Edition (or a separately-licensed GoldenGate). The lesson: **edition gates the method** — check it before you design.

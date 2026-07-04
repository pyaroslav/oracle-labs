-- PATCHING LAB — read your patch level and the SQL-patch registry. 100% read-only.
-- Connects as SYS to the CDB root. Companion to the post
-- "Oracle Patching, Demystified: CPU, RU, RUR — and What Changed in 2026".
set linesize 180
set pagesize 200
set feedback off
column comp_name    format a44
column version      format a16
column status       format a10
column patch_id     format 9999999999
column action       format a10
column p_status     format a9
column action_time  format a17
column description  format a46

prompt =====================================================================
prompt  1. YOUR RELEASE / RU LEVEL
prompt =====================================================================
prompt  Format: release.RU.RUR.reserved.datestamp
prompt  e.g. 19.26.0.0.0 = 19c, Release Update 26 (the 2nd digit is the RU).
select version_full from v$instance;

prompt
prompt =====================================================================
prompt  2. REGISTRY COMPONENTS (what's installed, and its version)
prompt =====================================================================
select comp_name, version, status from dba_registry order by comp_name;

prompt
prompt =====================================================================
prompt  3. THE SQL-PATCH REGISTRY  --  DBA_REGISTRY_SQLPATCH
prompt =====================================================================
prompt  This is what "datapatch" writes. It is where you PROVE the SQL half of
prompt  a patch actually ran after OPatch patched the binaries.
prompt  On this base Free image the history is minimal; on a patched production
prompt  database every RU you applied appears here with STATUS = SUCCESS.
select patch_id,
       action,
       status                                   as p_status,
       to_char(action_time,'YYYY-MM-DD HH24:MI') as action_time,
       description
from   dba_registry_sqlpatch
order  by action_time;

prompt
prompt >> Reading guide
prompt >>   - v$instance.version_full  -> your RU (2nd digit).
prompt >>   - DBA_REGISTRY_SQLPATCH    -> proof datapatch ran (the SQL side).
prompt >>   - If an RU is in the binaries (opatch lspatches) but MISSING here,
prompt >>     someone skipped datapatch and the database is half-patched.
set feedback on
exit

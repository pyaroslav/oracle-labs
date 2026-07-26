-- audit.sql — score FREEPDB1 against the checklist. Emits one KEY=<violations> line per SQL check;
-- run.sh reads them and prints the PASS/FAIL table. The default-password check is a live login test
-- done from run.sh (you can't prove "this password works" from a dictionary view alone). Run as SYSDBA.
set heading off feedback off pagesize 0 verify off linesize 200 trimspool on
alter session set container = FREEPDB1;

-- 2a. EXECUTE on network/file packages granted to PUBLIC.
select 'PUBLIC_NET='||count(*) from dba_tab_privs
 where grantee = 'PUBLIC' and privilege = 'EXECUTE'
   and table_name in ('UTL_HTTP','UTL_TCP','UTL_SMTP','UTL_INADDR','UTL_FILE');

-- 2b. %ANY% system privileges held by customer-created (non Oracle-maintained) accounts.
select 'ANY_PRIV='||count(*) from dba_sys_privs p
   join dba_users u on u.username = p.grantee
 where u.oracle_maintained = 'N' and p.privilege like '%ANY%';

-- 2c. DBA / PDB_DBA granted to customer-created accounts, excluding the PDB's designated admin
--     (PDBADMIN legitimately holds PDB_DBA — it's the PDB administrator, like SYSTEM in the CDB).
select 'POWER_ROLE='||count(*) from dba_role_privs r
   join dba_users u on u.username = r.grantee
 where u.oracle_maintained = 'N' and r.granted_role in ('DBA','PDB_DBA')
   and r.grantee <> 'PDBADMIN';

-- 5. DEFAULT profile with no failed-login lockout.
select 'PROFILE_OPEN='||count(*) from dba_profiles
 where profile = 'DEFAULT' and resource_name = 'FAILED_LOGIN_ATTEMPTS' and limit = 'UNLIMITED';

-- 6. Unified-auditing baseline: how many of the two baseline policies are NOT enabled.
select 'AUDIT_OFF='||(2 - count(distinct policy_name)) from audit_unified_enabled_policies
 where policy_name in ('ORA_SECURECONFIG','ORA_LOGON_FAILURES');

exit

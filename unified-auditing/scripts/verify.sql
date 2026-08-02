-- verify.sql — flush the queued audit buffer, then count the records each policy should have captured.
-- Emits KEY=<count> lines that run.sh turns into the PASS/FAIL table. Run as SYSDBA.
set heading off feedback off pagesize 0 verify off linesize 200
alter session set container = FREEPDB1;

-- queued (async) mode buffers records in the SGA; force them to the trail before we look.
exec dbms_audit_mgmt.flush_unified_audit_trail;

-- 1. the failed login (captured by ORA_LOGON_FAILURES) -- ORA-01017 = invalid credentials
select 'FAILED_LOGIN='||count(*) from unified_audit_trail
 where action_name = 'LOGON' and return_code <> 0;

-- 2. the CREATE USER (captured by ORA_SECURECONFIG)
select 'CREATE_USER='||count(*) from unified_audit_trail
 where action_name = 'CREATE USER' and unified_audit_policies like '%ORA_SECURECONFIG%';

-- 3. the read of the sensitive table (captured by our custom policy)
select 'SENSITIVE_SELECT='||count(*) from unified_audit_trail
 where action_name = 'SELECT' and object_name = 'EMPLOYEE_SALARY'
   and unified_audit_policies like '%AUD_SALARY_ACCESS%';

exit

-- analyze.sql — stop the capture, compute the result, and report what APPUSER USED vs what sat UNUSED.
-- Run as SYSDBA. DBMS_PRIVILEGE_CAPTURE.GENERATE_RESULT must run before the DBA_*_PRIVS views are populated.
-- Privilege names contain spaces; we replace ' ' with '_' so run.sh's whitespace-stripping sig() keeps them
-- intact (CREATE SESSION -> CREATE_SESSION). Markers must not end in '-'.
set echo off feedback off verify off heading off pagesize 0 linesize 32767 trimspool on
alter session set container = FREEPDB1;

begin
  dbms_privilege_capture.disable_capture('APPUSER_CAP');
  dbms_privilege_capture.generate_result('APPUSER_CAP');
end;
/

prompt >>>SIGNALS
select 'USED_SYS='  ||listagg(replace(sys_priv,' ','_'),',') within group (order by sys_priv)
  from dba_used_sysprivs   where capture = 'APPUSER_CAP' and username = 'APPUSER';
select 'UNUSED_SYS='||listagg(replace(sys_priv,' ','_'),',') within group (order by sys_priv)
  from dba_unused_sysprivs where capture = 'APPUSER_CAP' and username = 'APPUSER';
select 'USED_OBJ='  ||listagg(object_name,',') within group (order by object_name)
  from dba_used_objprivs   where capture = 'APPUSER_CAP' and username = 'APPUSER' and object_owner = 'PAOWN';
select 'UNUSED_OBJ='||listagg(object_name,',') within group (order by object_name)
  from dba_unused_objprivs where capture = 'APPUSER_CAP' and username = 'APPUSER' and object_owner = 'PAOWN';
select 'NUSED='  ||count(*) from dba_used_privs   where capture = 'APPUSER_CAP' and username = 'APPUSER';
select 'NUNUSED='||count(*) from dba_unused_privs where capture = 'APPUSER_CAP' and username = 'APPUSER';
prompt >>>ENDSIGNALS
exit

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
-- Count only what PA_ROLE granted (system privs + PAOWN object privs). DBA_USED_PRIVS also lists privileges that
-- reach every user through PUBLIC (e.g. on SYS objects touched at login), which would inflate "used X of Y".
select 'NUSED='  ||((select count(*) from dba_used_sysprivs   where capture = 'APPUSER_CAP' and username = 'APPUSER')
                  + (select count(*) from dba_used_objprivs   where capture = 'APPUSER_CAP' and username = 'APPUSER'
                                                                and object_owner = 'PAOWN')) from dual;
select 'NUNUSED='||((select count(*) from dba_unused_sysprivs where capture = 'APPUSER_CAP' and username = 'APPUSER')
                  + (select count(*) from dba_unused_objprivs where capture = 'APPUSER_CAP' and username = 'APPUSER'
                                                                and object_owner = 'PAOWN')) from dual;
prompt >>>ENDSIGNALS
exit

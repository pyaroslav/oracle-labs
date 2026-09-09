-- meta.sql — ground-truth facts for the setup drill, read as SYSDBA: is the capture enabled, and how
-- many privileges did PA_ROLE actually hand APPUSER (the size of the over-grant).
-- NOTE: prompt markers must NOT end in '-' (SQL*Plus treats a trailing hyphen as line continuation).
set echo off feedback off verify off heading off pagesize 0 linesize 300 trimspool on
alter session set container = FREEPDB1;

prompt >>>SIGNALS
select 'CAP_ENABLED='||nvl(max(enabled),'MISSING') from dba_priv_captures where name = 'APPUSER_CAP';
select 'GRANTED='||(
  (select count(*) from role_sys_privs where role = 'PA_ROLE') +
  (select count(*) from role_tab_privs where role = 'PA_ROLE')) from dual;
prompt >>>ENDSIGNALS
exit

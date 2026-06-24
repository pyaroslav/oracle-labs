-- ============================================================================
-- Deadlock lab — SETUP. Run as SYS (sqlplus -s -L "/ as sysdba").
-- Builds a 2-row table in FREEPDB1. That is the entire dataset a deadlock
-- needs: two rows, two sessions, two cross-locked TX enqueues. App user is
-- 'labuser' / 'Lab_Passw0rd1' (created by the gvenzl image). Idempotent.
-- ============================================================================
set echo off feedback off verify off heading off serveroutput on
whenever sqlerror continue
alter session set container = FREEPDB1;

prompt >> Ensuring app user 'labuser' exists with quota...
declare n number;
begin
  select count(*) into n from dba_users where username = 'LABUSER';
  if n = 0 then execute immediate 'create user labuser identified by "Lab_Passw0rd1"'; end if;
  execute immediate 'grant create session, create table to labuser';
  execute immediate 'alter user labuser quota unlimited on users';
end;
/

prompt >> (Re)building labuser.dl_acct with two rows (id=1, id=2)...
declare n number;
begin
  select count(*) into n from dba_tables where owner='LABUSER' and table_name='DL_ACCT';
  if n > 0 then execute immediate 'drop table labuser.dl_acct purge'; end if;
end;
/
create table labuser.dl_acct (id number primary key, balance number);
insert into labuser.dl_acct values (1, 1000);
insert into labuser.dl_acct values (2, 2000);
commit;

set heading on
prompt
prompt Lab table ready:
select id, balance from labuser.dl_acct order by id;
exit

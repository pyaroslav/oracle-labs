-- setup.sql — run as SYSDBA. Builds HWM.T: 200,000 rows of ~200 bytes each (a few thousand blocks) in USERS, an
-- ASSM tablespace (SHRINK SPACE requires automatic segment space management). Demo data is generic and invented.
set echo off feedback off verify off heading off pagesize 0
alter session set container = FREEPDB1;
whenever sqlerror continue
drop user hwm cascade;
whenever sqlerror exit failure
create user hwm identified by "Hwm_Passw0rd1" quota unlimited on users;
grant create session, create table to hwm;
create table hwm.t (id number primary key, created date, pad varchar2(200)) tablespace users;
insert /*+ append */ into hwm.t
  select level, date '2026-01-01' + mod(level, 365), rpad('row ' || level, 200, '.')
  from dual connect by level <= 200000;
commit;
exec dbms_stats.gather_table_stats('HWM', 'T')
exit

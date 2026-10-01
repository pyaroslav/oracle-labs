-- setup.sql — run as SYSDBA. Creates the APP user in FREEPDB1 with one table of "confidential" rows. The
-- marker value CANARY-7731-CONFIDENTIAL is what we look for in the packet capture. Demo data is invented.
set echo off feedback off verify off heading off pagesize 0
alter session set container = FREEPDB1;
whenever sqlerror continue
drop user app cascade;
whenever sqlerror exit failure
create user app identified by "App_Passw0rd1" quota unlimited on users;
grant create session, create table to app;
grant select on sys.v_$session_connect_info to app;
create table app.vault (id number primary key, owner varchar2(40), secret varchar2(60));
insert into app.vault values (1, 'Payroll export', 'CANARY-7731-CONFIDENTIAL');
insert into app.vault values (2, 'Partner API',   'CANARY-7732-CONFIDENTIAL');
commit;
exit

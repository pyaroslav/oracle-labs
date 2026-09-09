-- setup.sql — Privilege Analysis lab. Build a deliberately OVER-privileged user and start a privilege
-- capture scoped to it, so the workload + analyze drills can show what it ACTUALLY used vs what it was
-- granted. Run as SYSDBA. Idempotent (safe to re-run).
--
-- The whole point: real accounts accrue far more privilege than they use ("just give it DBA so the ticket
-- closes"). DBMS_PRIVILEGE_CAPTURE records the privileges a session really exercises, so you can compare
-- USED vs UNUSED and revoke the difference — least privilege, proven from evidence instead of guessed.
set echo off feedback off verify off
whenever sqlerror continue
alter session set container = FREEPDB1;

-- clean slate ---------------------------------------------------------------------------------------
begin dbms_privilege_capture.disable_capture('APPUSER_CAP'); exception when others then null; end;
/
begin dbms_privilege_capture.drop_capture('APPUSER_CAP');    exception when others then null; end;
/
begin execute immediate 'drop user appuser cascade'; exception when others then null; end;
/
begin execute immediate 'drop role pa_role';         exception when others then null; end;
/
begin execute immediate 'drop user paown cascade';   exception when others then null; end;
/

-- a small owner schema with two tables the app could read ------------------------------------------
create user paown identified by "Lab_Passw0rd1" default tablespace users quota unlimited on users;
grant create session, create table to paown;
create table paown.customers (id number primary key, name varchar2(40));
create table paown.orders    (id number primary key, amount number);
insert into paown.customers select rownum, 'Cust_'||rownum from dual connect by level <= 100;
insert into paown.orders    select rownum, rownum*10       from dual connect by level <= 100;
commit;

-- === the OVER-GRANT: a role carrying far more than any one app needs ================================
create role pa_role;
grant create session   to pa_role;
grant create table     to pa_role;
grant create view      to pa_role;
grant create procedure to pa_role;
grant create sequence  to pa_role;
grant create synonym   to pa_role;
grant select any table to pa_role;
grant create any table to pa_role;
grant drop any table   to pa_role;
grant alter any table  to pa_role;
grant select on paown.customers to pa_role;
grant select on paown.orders    to pa_role;

create user appuser identified by "Lab_Passw0rd1" default tablespace users quota unlimited on users;
grant pa_role to appuser;

-- === start capturing exactly what APPUSER uses (context capture scoped to that session user) =========
begin
  dbms_privilege_capture.create_capture(
    name        => 'APPUSER_CAP',
    description => 'What APPUSER actually uses vs what it was granted',
    type        => dbms_privilege_capture.g_context,
    condition   => 'SYS_CONTEXT(''USERENV'',''SESSION_USER'') = ''APPUSER''');
  dbms_privilege_capture.enable_capture('APPUSER_CAP');
end;
/
exit

-- setup.sql — build the bind-variables lab schema: one small table the drills query 1,000 times.
-- Run as SYSDBA; switch into the PDB first. Idempotent (drops+recreates the user).
-- NOTE: SQL*Plus treats a trailing '-' as line continuation, so prompt/marker lines never end in a hyphen.
set echo off feedback off verify off heading off pagesize 0 linesize 200 trimspool on
alter session set container = FREEPDB1;

begin execute immediate 'drop user bindlab cascade'; exception when others then null; end;
/
create user bindlab identified by "Lab_Passw0rd1" quota unlimited on users;
grant create session to bindlab;

create table bindlab.widgets (id number primary key, val varchar2(40));
insert into bindlab.widgets select level, 'widget_'||level from dual connect by level <= 1000;
commit;

begin dbms_stats.gather_table_stats('BINDLAB','WIDGETS'); end;
/
exit

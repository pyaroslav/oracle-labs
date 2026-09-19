-- setup.sql — build the snapshot-too-old lab: a 20,000-row table to scan, plus a deliberately WEAK undo
-- configuration (a tiny, non-autoextending undo tablespace with retention NOT guaranteed) so a long query's
-- read-consistent undo can be overwritten by concurrent DML. Run as SYSDBA; switch into the PDB first.
-- NOTE: SQL*Plus treats a trailing '-' as line continuation, so marker lines never end in a hyphen.
set echo off feedback off verify off heading off pagesize 0 linesize 200 trimspool on
alter session set container = FREEPDB1;

-- schema + data
begin execute immediate 'drop user snap cascade'; exception when others then null; end;
/
create user snap identified by "Lab_Passw0rd1" quota unlimited on users;
grant create session, create table to snap;

create table snap.t (id number, pad varchar2(200));
insert into snap.t select level, lpad('x', 200, 'x') from dual connect by level <= 20000;
commit;
create table snap.result (k varchar2(30), v varchar2(200));

-- the weak undo config: 25 MB, autoextend OFF, retention NOT guaranteed. Big enough that one full-table update
-- fits, but small enough that repeated churn wraps it and overwrites the long query's read-consistent undo.
begin execute immediate 'alter system set undo_tablespace = UNDOTBS1 scope=both'; exception when others then null; end;
/
begin execute immediate 'drop tablespace undo_small including contents and datafiles'; exception when others then null; end;
/
create undo tablespace undo_small datafile '/opt/oracle/oradata/FREE/FREEPDB1/undo_small.dbf' size 25m reuse autoextend off;
alter tablespace undo_small retention noguarantee;
alter system set undo_tablespace = undo_small scope=both;
alter system set undo_retention = 1 scope=both;
exit

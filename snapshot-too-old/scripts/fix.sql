-- fix.sql — the remedy for ORA-01555: an undo tablespace sized for the workload, with RETENTION GUARANTEE so
-- Oracle will never overwrite unexpired undo (it would rather fail a DML than let a read go inconsistent), and
-- an undo_retention long enough to cover the longest-running query. Applied between the failing run and the
-- successful re-run of the exact same query. Run as SYSDBA in the PDB.
set echo off feedback off verify off heading off pagesize 0 linesize 200 trimspool on
alter session set container = FREEPDB1;

-- switch active undo away first so undo_big (if it exists from a prior run) can be dropped, then rebuild it.
alter system set undo_tablespace = UNDOTBS1 scope=both;
begin execute immediate 'drop tablespace undo_big including contents and datafiles'; exception when others then null; end;
/
create undo tablespace undo_big datafile '/opt/oracle/oradata/FREE/FREEPDB1/undo_big.dbf' size 300m reuse autoextend on next 50m maxsize 800m;
alter tablespace undo_big retention guarantee;
alter system set undo_tablespace = undo_big scope=both;
alter system set undo_retention = 1200 scope=both;
exit

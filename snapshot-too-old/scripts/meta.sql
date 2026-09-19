-- meta.sql — ground-truth facts for the setup drill, read as SYSDBA: the table row count and the active undo
-- tablespace (should be the weak UNDO_SMALL after setup).
set echo off feedback off verify off heading off pagesize 0 linesize 200 trimspool on
alter session set container = FREEPDB1;
prompt >>>SIGNALS
select 'ROWS='||count(*) from snap.t;
select 'UNDO='||upper(value) from v$parameter where name = 'undo_tablespace';
prompt >>>ENDSIGNALS
exit

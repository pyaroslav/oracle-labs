-- switch.sql — force a redo log switch at the CDB root (ALTER SYSTEM SWITCH LOGFILE is not allowed from inside a
-- PDB). Each switch archives the outgoing redo log into the FRA. Guarded so a switch that fails once the archiver
-- is stuck doesn't abort the caller. Run as SYSDBA at the CDB root.
set echo off feedback off verify off heading off pagesize 0 linesize 200 trimspool on
begin execute immediate 'alter system switch logfile'; exception when others then null; end;
/
exit

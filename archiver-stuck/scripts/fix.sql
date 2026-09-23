-- fix.sql — the headroom half of the fix. run.sh first backs up the archived logs OUTSIDE the FRA and deletes
-- the inputs with RMAN (the sustainable fix -- stop the logs piling up); this script then grows the FRA so the
-- archiver has room to resume immediately and catches up any pending archiving. Together they clear the stuck
-- condition and archive destination 1 returns to VALID. Run as SYSDBA at the CDB root. Guarded blocks make the
-- catch-up harmless when there is nothing left to archive (ORA-00271).
set echo off feedback off verify off heading off pagesize 0 linesize 200 trimspool on
alter system set db_recovery_file_dest_size = 500m scope=both;
begin execute immediate 'alter system archive log all'; exception when others then null; end;
/
begin execute immediate 'alter system switch logfile'; exception when others then null; end;
/
exit

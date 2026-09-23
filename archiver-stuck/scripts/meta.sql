-- meta.sql — ground-truth facts for the setup drill, read as SYSDBA at the CDB root: archive-log mode, the FRA
-- size (should be the tiny 50 MB lab size), and that the redo-generating schema exists in the PDB.
set echo off feedback off verify off heading off pagesize 0 linesize 200 trimspool on
prompt >>>SIGNALS
select 'LOGMODE='||log_mode from v$database;
select 'FRASIZE_MB='||to_char(round(to_number(value)/1024/1024)) from v$parameter where name = 'db_recovery_file_dest_size';
alter session set container = FREEPDB1;
select 'ARC_EXISTS='||count(*) from all_tables where owner = 'ARC' and table_name = 'T';
prompt >>>ENDSIGNALS
exit

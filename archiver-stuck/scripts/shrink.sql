-- shrink.sql — squeeze the Fast Recovery Area down to the tiny lab size AFTER run.sh has cleared any old
-- archived logs, so only a couple of log switches are needed to fill it. Run as SYSDBA at the CDB root.
set echo off feedback off verify off heading off pagesize 0 linesize 200 trimspool on
alter system set db_recovery_file_dest_size = 50m scope=both;
exit

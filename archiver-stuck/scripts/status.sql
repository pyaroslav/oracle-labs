-- status.sql — the current archiver state, read as SYSDBA at the CDB root: how full the FRA is (percent), and
-- the status + last error of archive destination 1. run.sh reads FRA_PCT and DEST_STATUS from these signals to
-- drive the reproduce/fix loops. NOTE: marker lines never end in a hyphen (SQL*Plus line-continuation).
set echo off feedback off verify off heading off pagesize 0 linesize 200 trimspool on
prompt >>>SIGNALS
select 'FRA_PCT='||to_char(round(space_used/space_limit*100)) from v$recovery_file_dest;
select 'DEST_STATUS='||status from v$archive_dest where dest_id = 1;
select 'DEST_ERR='||nvl(substr(error,1,25),'none') from v$archive_dest where dest_id = 1;
prompt >>>ENDSIGNALS
exit

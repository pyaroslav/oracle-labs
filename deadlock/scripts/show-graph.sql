-- SQL-only fallback to surface ORA-00060 if you can't reach the trace file.
-- v$diag_alert_ext is queryable from the CDB root and holds the alert-log messages.
set echo off feedback off heading on pagesize 50 linesize 200 trimspool on
col ts format a10
col message_text format a150
select to_char(originating_timestamp,'HH24:MI:SS') ts, message_text
from   v$diag_alert_ext
where  message_text like '%ORA-00060%'
order  by originating_timestamp desc
fetch first 3 rows only;
exit

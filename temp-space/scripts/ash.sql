-- How you'd find the culprit on 19c, where the message has no SQL ID: ASH samples carry TEMP_SPACE_ALLOCATED.
-- (ASH is part of the Diagnostics Pack on Enterprise Edition; it's available on Oracle Database Free.)
set heading off feedback off pages 0 lines 200
alter session set container=FREEPDB1;
select sql_id || '  ' || count(*) || ' samples, peak ' || round(max(temp_space_allocated) / 1048576) || ' MB of TEMP'
from v$active_session_history
where sample_time > systimestamp - interval '2' minute and temp_space_allocated > 0
group by sql_id order by max(temp_space_allocated) desc fetch first 3 rows only;
exit

-- Temp the fixed report needed: the largest one-pass/multi-pass spill recorded for its work areas.
set heading off feedback off pages 0 lines 200
alter session set container=FREEPDB1;
select 'FIXED_TEMP_MB=' || nvl(round(max(w.max_tempseg_size) / 1048576), 0)
from v$sql s join v$sql_workarea w on w.sql_id = s.sql_id
where s.sql_text like '%open_orders_report_fixed%' and s.sql_text not like '%v$sql%';
select 'FIXED_SQL_SEEN=' || count(*) from v$sql where sql_text like '%open_orders_report_fixed%' and sql_text not like '%v$sql%';
exit

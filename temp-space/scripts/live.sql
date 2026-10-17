-- Who holds TEMP right now. SQL_ID is the session's last-parsed statement; SQL_ID_TEMPSEG is the one that owns the
-- temp segment. KEY=value lines for run.sh.
set heading off feedback off pages 0 lines 200
alter session set container=FREEPDB1;
select 'LIVE_SQL_ID=' || max(u.sql_id) from v$tempseg_usage u where u.tablespace = 'TEMP_SMALL';
select 'LIVE_SQL_ID_TEMPSEG=' || max(u.sql_id_tempseg) from v$tempseg_usage u where u.tablespace = 'TEMP_SMALL';
select 'LIVE_MB=' || round(sum(u.blocks) * 8192 / 1048576) from v$tempseg_usage u where u.tablespace = 'TEMP_SMALL';
select 'LIVE_SQL_ID_TEXT=' || replace(substr(max(s.sql_text), 1, 60), ' ', '~')
from v$sql s where s.sql_id = (select max(sql_id) from v$tempseg_usage where tablespace = 'TEMP_SMALL');
exit

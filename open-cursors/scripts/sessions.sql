-- Per APP session: what the error counts ('opened cursors current') vs. raw V$OPEN_CURSOR rows
set lines 200 pages 0 feedback off
alter session set container = FREEPDB1;
select 'SESS sid=' || s.sid || ' module=' || nvl(s.module, '-')
       || ' opened_current=' || st.value
       || ' v$open_cursor_rows=' || (select count(*) from v$open_cursor o where o.sid = s.sid)
       || ' open_type_rows=' || (select count(*) from v$open_cursor o where o.sid = s.sid and o.cursor_type like 'OPEN%')
from v$sesstat st
join v$statname n on n.statistic# = st.statistic#
join v$session  s on s.sid = st.sid
where n.name = 'opened cursors current' and s.username = 'APP'
order by st.value desc;
select 'TYPE sid=' || o.sid || ' ' || o.cursor_type || '=' || count(*)
from v$open_cursor o join v$session s on s.sid = o.sid
where s.username = 'APP'
group by o.sid, o.cursor_type order by o.sid, count(*) desc;
exit

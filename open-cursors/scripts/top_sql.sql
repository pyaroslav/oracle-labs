-- Which statement is the session holding open? Only rows the session really has open (not cached).
set lines 200 pages 0 feedback off
alter session set container = FREEPDB1;
select 'TOP sid=' || o.sid || ' sql_id=' || o.sql_id || ' open=' || count(*) || ' text=' || max(o.sql_text)
from v$open_cursor o join v$session s on s.sid = o.sid
where s.username = 'APP' and o.cursor_type like 'OPEN%'
group by o.sid, o.sql_id
having count(*) > 10
order by count(*) desc;
exit

-- One execution of the SAME statement with a bind value (&1), in a fresh session. Prints:
--   GETS  = logical reads this execution did, CHILD = child cursor it ran, JOIN = that child's join method,
--   BSENS / BAWARE = adaptive cursor sharing flags of that child, ROWS = rows the join produced.
set feedback off heading off verify off pagesize 0 linesize 200 trimspool on
whenever sqlerror exit failure
variable s varchar2(10)
exec :s := '&1'
column g0 new_value g0 noprint
select value g0 from v$mystat m join v$statname n using (statistic#) where n.name = 'session logical reads';
select 'ROWS='||count(c.region) from acs.orders o join acs.customers c on c.cust_id = o.cust_id where o.status = :s /* acs_demo */;
select 'GETS='||(m.value - &g0 - 0)||chr(10)||'CHILD='||s.prev_child_number||chr(10)||'SQLID='||s.prev_sql_id
from   v$mystat m join v$statname n using (statistic#), v$session s
where  n.name = 'session logical reads' and s.sid = sys_context('userenv','sid');
exit

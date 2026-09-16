-- binds.sql — run the SAME 1,000 queries, but with the value passed as a BIND VARIABLE (:b). Now Oracle
-- sees ONE SQL text, so there is a single parent cursor, one hard parse, and 1,000 executions of it. Same
-- measurement method as literals.sql (flush, snapshot 'parse count (hard)' before/after, read V$SQL).
set echo off feedback off verify off heading off pagesize 0 linesize 200 trimspool on
alter session set container = FREEPDB1;
alter system flush shared_pool;

-- warm the table's recursive dictionary SQL (and the bind cursor itself) BEFORE we snapshot, so the
-- before/after delta reflects only the loop, not one-time post-flush dictionary reparsing.
declare n number; begin execute immediate 'select count(*) from bindlab.widgets where id = :b' into n using -1; end;
/

column v new_value hp_before noprint
select value v from v$mystat s join v$statname n on s.statistic# = n.statistic# where n.name = 'parse count (hard)';

declare n number;
begin
  for i in 1..1000 loop
    execute immediate 'select count(*) from bindlab.widgets where id = :b' into n using i;
  end loop;
end;
/

column v new_value hp_after noprint
select value v from v$mystat s join v$statname n on s.statistic# = n.statistic# where n.name = 'parse count (hard)';

prompt >>>SIGNALS
select 'BIND_CURSORS='||count(*)          from v$sql where sql_text like 'select count(*) from bindlab.widgets where id = :b';
select 'BIND_HARD_PARSES='||(&hp_after - &hp_before) from dual;
select 'BIND_EXECS='||nvl(max(executions),0)         from v$sql where sql_text like 'select count(*) from bindlab.widgets where id = :b';
select 'BIND_MEM_KB='||round(nvl(sum(sharable_mem),0)/1024) from v$sql where sql_text like 'select count(*) from bindlab.widgets where id = :b';
prompt >>>ENDSIGNALS
exit

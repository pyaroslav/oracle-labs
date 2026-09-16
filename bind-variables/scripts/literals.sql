-- literals.sql — run the SAME logical query 1,000 times with the value baked in as a LITERAL, so every
-- iteration is a distinct SQL text: a distinct parent cursor in V$SQL and a hard parse. Read as SYSDBA in
-- the PDB. Flush the shared pool first so the counts start clean; snapshot 'parse count (hard)' from
-- V$MYSTAT before and after the loop and diff it.
set echo off feedback off verify off heading off pagesize 0 linesize 200 trimspool on
alter session set container = FREEPDB1;
alter system flush shared_pool;

-- warm the table's recursive dictionary SQL (via a BIND so it adds no literal cursor) BEFORE we snapshot,
-- so the before/after delta reflects only the loop's own parses, not one-time post-flush dictionary reparsing.
declare n number; begin execute immediate 'select count(*) from bindlab.widgets where id = :b' into n using -1; end;
/

column v new_value hp_before noprint
select value v from v$mystat s join v$statname n on s.statistic# = n.statistic# where n.name = 'parse count (hard)';

declare n number;
begin
  for i in 1..1000 loop
    execute immediate 'select count(*) from bindlab.widgets where id = '||i into n;
  end loop;
end;
/

column v new_value hp_after noprint
select value v from v$mystat s join v$statname n on s.statistic# = n.statistic# where n.name = 'parse count (hard)';

prompt >>>SIGNALS
select 'LIT_CURSORS='||count(*) from v$sql
  where sql_text like 'select count(*) from bindlab.widgets where id = %' and sql_text not like '%:b';
select 'LIT_HARD_PARSES='||(&hp_after - &hp_before) from dual;
select 'LIT_MEM_KB='||round(nvl(sum(sharable_mem),0)/1024) from v$sql
  where sql_text like 'select count(*) from bindlab.widgets where id = %' and sql_text not like '%:b';
prompt >>>ENDSIGNALS
exit

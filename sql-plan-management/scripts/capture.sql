-- capture.sql — capture the good INDEX plan (the one the optimizer picks while the histogram is in place)
-- as an ACCEPTED, ENABLED SQL plan baseline. Run as SYSDBA.
--
-- Method: automatic capture. With OPTIMIZER_CAPTURE_SQL_PLAN_BASELINES = TRUE, Oracle records a baseline
-- for a repeatable statement and auto-accepts its first plan. We run the statement twice (first execution
-- registers it as repeatable, second captures the plan), then turn capture back off. The query text is
-- byte-for-byte identical to probe.sql, so the SQL signatures match and the baseline applies to what the
-- probe runs later.
--
-- (Why not LOAD_PLANS_FROM_CURSOR_CACHE? A SORT AGGREGATE cursor can report PLAN_HASH_VALUE 0 in the
-- cursor cache, and the loader has no plan to copy — it returns 0. Automatic capture is the reliable path.)
set echo off feedback off verify off heading off pagesize 0 linesize 200 trimspool on
alter session set container = FREEPDB1;
alter session set optimizer_adaptive_plans = false;

alter session set optimizer_capture_sql_plan_baselines = true;
select /*+ GATHER_PLAN_STATISTICS */ sum(amount)
from   shop.orders
where  status = 'OPEN';
select /*+ GATHER_PLAN_STATISTICS */ sum(amount)
from   shop.orders
where  status = 'OPEN';
alter session set optimizer_capture_sql_plan_baselines = false;

-- report how many accepted baselines now exist for our statement (run.sh asserts on this).
-- A plain SELECT, not DBMS_OUTPUT -- serveroutput does not print under `set pagesize 0`.
prompt >>>SIGNALS
select 'BASELINES_LOADED='||count(*)
from   dba_sql_plan_baselines
where  sql_text like '%shop.orders%' and accepted = 'YES';
prompt >>>ENDSIGNALS
exit

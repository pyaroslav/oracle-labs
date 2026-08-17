-- probe.sql — run the protected statement with SQL plan baselines either ON or OFF (&USE_SPM), print the
-- REAL plan (E-Rows vs A-Rows), and emit machine-readable signals for run.sh. Run as SYSDBA.
-- The driver pipes `define USE_SPM=TRUE|FALSE` ahead of this script, so the same probe shows both the
-- regression (baselines off) and the save (baselines on).
-- NOTE: prompt markers must NOT end in '-' -- SQL*Plus treats a trailing hyphen as line continuation.
set echo off feedback off verify off heading off pagesize 0 linesize 200 trimspool on define on
alter session set container = FREEPDB1;
alter session set statistics_level = all;
alter session set optimizer_adaptive_plans = false;
alter session set optimizer_use_sql_plan_baselines = &USE_SPM;

-- identical text to capture.sql -> same SQL signature -> the baseline applies
select /*+ GATHER_PLAN_STATISTICS */ sum(amount)
from   shop.orders
where  status = 'OPEN';

-- capture the cursor we just executed
column l_sqlid new_value V_SQLID noprint
column l_child new_value V_CHILD noprint
select prev_sql_id l_sqlid, prev_child_number l_child
from   v$session
where  sid = sys_context('userenv','sid');

-- human-readable plan; the Note section reports a SQL plan baseline when one was used
prompt >>>PLAN
select plan_table_output
from   table(dbms_xplan.display_cursor('&V_SQLID', &V_CHILD, 'ALLSTATS LAST'));
prompt >>>ENDPLAN

-- machine-readable signals: which access path, and whether a baseline built the plan
prompt >>>SIGNALS
select 'HAS_FULL='||count(*)
from   v$sql_plan_statistics_all
where  sql_id = '&V_SQLID' and child_number = &V_CHILD
   and operation = 'TABLE ACCESS' and options = 'FULL' and object_name = 'ORDERS';

select 'HAS_INDEX='||count(*)
from   v$sql_plan_statistics_all
where  sql_id = '&V_SQLID' and child_number = &V_CHILD
   and operation = 'INDEX' and object_name = 'ORDERS_STATUS_IX';

select 'BASELINE='||count(*)
from   v$sql
where  sql_id = '&V_SQLID' and child_number = &V_CHILD
   and sql_plan_baseline is not null;
prompt >>>ENDSIGNALS
exit

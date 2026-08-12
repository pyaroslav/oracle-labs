-- probe.sql — run a join whose filter is on two correlated columns, print the REAL plan (E-Rows vs
-- A-Rows), and emit machine-readable signals for run.sh. Run as SYSDBA. Called identically before and
-- after the fix; the only thing that changes is whether a (make, model) column group exists.
-- NOTE: prompt markers must NOT end in '-' -- SQL*Plus treats a trailing hyphen as line continuation.
set echo off feedback off verify off heading off pagesize 0 linesize 200 trimspool on define on
alter session set container = FREEPDB1;
alter session set statistics_level = all;
alter session set optimizer_adaptive_plans = false;

-- the probe: join filtered by two predicates on correlated columns (MODEL_050 belongs to MAKE_025)
select /*+ GATHER_PLAN_STATISTICS */ sum(o.amount)
from   sales.cars c, sales.orders o
where  c.id = o.car_id
   and c.make = 'MAKE_025' and c.model = 'MODEL_050';

-- capture the cursor we just executed
column l_sqlid new_value V_SQLID noprint
column l_child new_value V_CHILD noprint
select prev_sql_id l_sqlid, prev_child_number l_child
from   v$session
where  sid = sys_context('userenv','sid');

-- human-readable plan with estimates next to reality
prompt >>>PLAN
select plan_table_output
from   table(dbms_xplan.display_cursor('&V_SQLID', &V_CHILD, 'ALLSTATS LAST'));
prompt >>>ENDPLAN

-- machine-readable signals: which join method, and the driving E-Rows/A-Rows on the CARS filter
prompt >>>SIGNALS
select 'HAS_NL='||count(*)
from   v$sql_plan_statistics_all
where  sql_id = '&V_SQLID' and child_number = &V_CHILD
   and operation = 'NESTED LOOPS';

select 'HAS_HASH='||count(*)
from   v$sql_plan_statistics_all
where  sql_id = '&V_SQLID' and child_number = &V_CHILD
   and operation = 'HASH JOIN';

-- the TABLE ACCESS on CARS carries the correlated-filter estimate (under-counted before the fix)
select 'EROWS='||cardinality||' AROWS='||nvl(last_output_rows, 0)
from   ( select cardinality, last_output_rows
         from   v$sql_plan_statistics_all
         where  sql_id = '&V_SQLID' and child_number = &V_CHILD
            and operation = 'TABLE ACCESS' and object_name = 'CARS'
         order  by id )
where  rownum = 1;
prompt >>>ENDSIGNALS
exit

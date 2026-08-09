-- probe.sql — run the skewed-predicate query, print the REAL plan (E-Rows vs A-Rows), and emit
-- machine-readable signals for run.sh. Run as SYSDBA. Called identically before and after the fix;
-- the only thing that changes between calls is whether a histogram exists.
-- NOTE: prompt markers must NOT end in '-' — SQL*Plus treats a trailing hyphen as line continuation.
set echo off feedback off verify off heading off pagesize 0 linesize 200 trimspool on define on
alter session set container = FREEPDB1;
alter session set statistics_level = all;   -- capture actual row counts for every row source

-- the probe: a single equality predicate on a heavily skewed column
select /*+ GATHER_PLAN_STATISTICS */ sum(amount) from shop.orders where status = 'OPEN';

-- capture the cursor we just executed (prev_sql_id/prev_child_number = the statement above)
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

-- machine-readable signals: is it a full scan or an index range scan, and the driving E-Rows/A-Rows
prompt >>>SIGNALS
select 'HAS_FULL='||count(*)
from   v$sql_plan_statistics_all
where  sql_id = '&V_SQLID' and child_number = &V_CHILD
   and operation = 'TABLE ACCESS' and options = 'FULL' and object_name = 'ORDERS';

select 'HAS_INDEX='||count(*)
from   v$sql_plan_statistics_all
where  sql_id = '&V_SQLID' and child_number = &V_CHILD
   and operation = 'INDEX' and options like '%RANGE SCAN%';

select 'EROWS='||cardinality||' AROWS='||nvl(last_output_rows, 0)
from   ( select cardinality, last_output_rows
         from   v$sql_plan_statistics_all
         where  sql_id = '&V_SQLID' and child_number = &V_CHILD
            and ( (operation = 'TABLE ACCESS' and options = 'FULL' and object_name = 'ORDERS')
               or (operation = 'INDEX' and options like '%RANGE SCAN%') )
         order  by id )
where  rownum = 1;
prompt >>>ENDSIGNALS
exit

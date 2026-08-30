-- probe.sql — run the SAME logical query (all June-2025 orders) two ways and show what pruning does.
--   A: WHERE order_date >= DATE '2025-06-01' AND order_date < DATE '2025-07-01'  -> Oracle PRUNES to 1 partition
--   B: WHERE TO_CHAR(order_date,'YYYY-MM') = '2025-06'                           -> a function on the key DEFEATS pruning
-- Same rows, but B scans every partition. Emits machine signals for run.sh plus the two real plans.
-- Run as SYSDBA. Prints Pstart/Pstop so you can see one partition vs all.
set echo off feedback off verify off heading off pagesize 0 linesize 220 trimspool on serveroutput off
alter session set container = FREEPDB1;

-- ===== QUERY A: range predicate on the partition key -> PRUNES =====
column ca new_value cnt_a noprint
select /*+ GATHER_PLAN_STATISTICS */ count(*) ca
  from sales.orders
  where order_date >= date '2025-06-01' and order_date < date '2025-07-01';
column sqa new_value sqlid_a noprint
column cha new_value child_a noprint
select prev_sql_id sqa, prev_child_number cha from v$session where sid = sys_context('userenv','sid');

-- ===== QUERY B: a FUNCTION on the partition key, same June-2025 rows -> pruning DEFEATED =====
column cb new_value cnt_b noprint
select /*+ GATHER_PLAN_STATISTICS */ count(*) cb
  from sales.orders
  where to_char(order_date, 'YYYY-MM') = '2025-06';
column sqb new_value sqlid_b noprint
column chb new_value child_b noprint
select prev_sql_id sqb, prev_child_number chb from v$session where sid = sys_context('userenv','sid');

prompt
prompt ====== PLAN A: WHERE order_date >= DATE '2025-06-01' AND < '2025-07-01'  (prunes) ======
select plan_table_output from table(dbms_xplan.display_cursor('&sqlid_a', &child_a, 'BASIC +PARTITION'));
prompt
prompt ====== PLAN B: WHERE TO_CHAR(order_date,'YYYY-MM') = '2025-06'  (no pruning) ======
select plan_table_output from table(dbms_xplan.display_cursor('&sqlid_b', &child_b, 'BASIC +PARTITION'));

prompt >>>SIGNALS
prompt PRUNE_COUNT=&cnt_a
prompt FULL_COUNT=&cnt_b
select 'PRUNE_OP='||operation||decode(options,null,'',' '||options) from v$sql_plan where sql_id='&sqlid_a' and child_number=&child_a and operation like 'PARTITION%' and rownum=1;
select 'FULL_OP=' ||operation||decode(options,null,'',' '||options) from v$sql_plan where sql_id='&sqlid_b' and child_number=&child_b and operation like 'PARTITION%' and rownum=1;
select 'PRUNE_PSTART='||partition_start from v$sql_plan where sql_id='&sqlid_a' and child_number=&child_a and operation like 'PARTITION%' and rownum=1;
select 'PRUNE_PSTOP=' ||partition_stop  from v$sql_plan where sql_id='&sqlid_a' and child_number=&child_a and operation like 'PARTITION%' and rownum=1;
select 'FULL_PSTART='||partition_start from v$sql_plan where sql_id='&sqlid_b' and child_number=&child_b and operation like 'PARTITION%' and rownum=1;
select 'FULL_PSTOP=' ||partition_stop  from v$sql_plan where sql_id='&sqlid_b' and child_number=&child_b and operation like 'PARTITION%' and rownum=1;
select 'PRUNE_BUFFERS='||buffer_gets from v$sql where sql_id='&sqlid_a' and child_number=&child_a;
select 'FULL_BUFFERS=' ||buffer_gets from v$sql where sql_id='&sqlid_b' and child_number=&child_b;
prompt >>>ENDSIGNALS
exit

-- The plan for the report, without running it. A failed statement's cursor doesn't reliably stay in the shared pool,
-- but EXPLAIN PLAN shows the same thing before the report ever runs.
set heading off feedback off pages 0 lines 200
explain plan for
select /* open_orders_report */ count(*) from (
  select distinct c.name, c.region, o.order_id, o.amount
  from orders o, customers c
  where o.status = 'OPEN');
select plan_table_output from table(dbms_xplan.display(null, null, 'BASIC +ROWS +BYTES'));
exit

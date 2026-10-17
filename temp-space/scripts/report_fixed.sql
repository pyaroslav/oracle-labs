-- The same report with the join predicate restored (DISTINCT kept, to show the join alone is the fix).
whenever sqlerror exit failure
set heading off feedback off pages 0 lines 300
select 'ROWS=' || count(*) from (
  select /* open_orders_report_fixed */ distinct c.name, c.region, o.order_id, o.amount
  from orders o, customers c
  where o.customer_id = c.customer_id
  and o.status = 'OPEN');
exit

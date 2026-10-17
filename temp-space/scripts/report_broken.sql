-- The open-orders report as it shipped: the join predicate o.customer_id = c.customer_id was lost in an edit, the
-- report showed duplicates, and DISTINCT was added to hide them. Every OPEN order now pairs with all 2,000 customers.
set heading off feedback off pages 0 lines 300
select /* open_orders_report */ count(*) from (
  select distinct c.name, c.region, o.order_id, o.amount
  from orders o, customers c
  where o.status = 'OPEN');
exit

-- setup.sql — build a 1,000,000-row ORDERS table with a SELECTIVE column (customer_id, ~100k distinct) and a
-- SKEWED low-cardinality column (status: 950,000 SHIPPED / 49,000 OPEN / 1,000 PENDING), index both, and
-- gather stats WITH a frequency histogram on status so the optimizer knows the skew. Run as SYSDBA. Idempotent.
--
-- The histogram is the point: without it the optimizer assumes status values are uniform (1/3 each) and can't
-- tell the common value from the rare one. With it, the same index on status is ignored for SHIPPED (95% of
-- rows -> a full scan is cheaper) and used for PENDING (0.1% -> an index range scan wins). The `wide` filler
-- makes the table big enough (~120MB) that a full scan is genuinely expensive, so the contrast is real.
set echo off feedback off verify off
whenever sqlerror continue
alter session set container = FREEPDB1;

begin execute immediate 'drop table shop.orders purge'; exception when others then null; end;
/
begin execute immediate 'drop user shop cascade';       exception when others then null; end;
/

create user shop identified by "Lab_Passw0rd1" default tablespace users quota unlimited on users;
grant create session, create table to shop;

create table shop.orders (
  id          number,
  customer_id number,
  status      varchar2(10),
  amount      number,
  filler      varchar2(100)
);

-- 1,000,000 rows: customer_id ~100k distinct (selective), status heavily skewed, wide filler
insert /*+ append */ into shop.orders
  select rownum,
         mod(rownum, 100000) + 1,
         case when rownum <= 1000  then 'PENDING'
              when rownum <= 50000 then 'OPEN'
              else                      'SHIPPED' end,
         mod(rownum, 1000) * 10,
         rpad('x', 100, 'x')
  from dual connect by level <= 1000000;
commit;

create index shop.idx_cust   on shop.orders(customer_id);
create index shop.idx_status on shop.orders(status);

-- frequency histogram on STATUS (only), so the optimizer sees the skew; index stats via cascade
begin
  dbms_stats.gather_table_stats(
    ownname    => 'SHOP',
    tabname    => 'ORDERS',
    method_opt => 'FOR ALL COLUMNS SIZE 1 FOR COLUMNS status SIZE 254',
    cascade    => true);
end;
/
exit

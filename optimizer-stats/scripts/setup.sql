-- setup.sql — a correlated table joined to a second table, with stats gathered WITHOUT a column group.
-- Run as SYSDBA. Idempotent (safe to re-run).
-- The point: the optimizer under-estimates the correlated filter, so it picks a nested loop join that is
-- right for a few hundred rows and wrong for ten thousand. An extended stat on (make, model) fixes it.
set echo off feedback off verify off
whenever sqlerror continue
alter session set container = FREEPDB1;

-- clean slate -------------------------------------------------------------------------------------
begin execute immediate 'drop user sales cascade'; exception when others then null; end;
/

create user sales identified by "Lab_Passw0rd1" quota unlimited on users;
grant create session, create table to sales;

-- the correlated table: 1,000,000 rows, 100 models (MODEL_000..099), 50 makes (MAKE_000..049),
-- 2 models per make. Both columns derive from the same value, so MODEL determines MAKE. ~10,000 rows/model.
-- NOTE: deliberately NO index on (make, model) -- a composite index would hand the optimizer the column
-- group's distinct-key count for free and mask the very problem this lab demonstrates.
create table sales.cars (
  id     number       not null,
  make   varchar2(20) not null,
  model  varchar2(20) not null
);
insert /*+ append */ into sales.cars (id, make, model)
select rownum,
       'MAKE_'  || lpad(floor(mod(rownum, 100) / 2), 3, '0'),
       'MODEL_' || lpad(mod(rownum, 100), 3, '0')
from   (select 1 from dual connect by level <= 1000),
       (select 1 from dual connect by level <= 1000);
commit;
alter table sales.cars add constraint cars_pk primary key (id);

-- the table we join to: one order per car, indexed on car_id so a nested loop is viable
create table sales.orders (
  order_id number not null,
  car_id   number not null,
  amount   number not null
);
insert /*+ append */ into sales.orders (order_id, car_id, amount)
select rownum, mod(rownum - 1, 1000000) + 1, mod(rownum, 1000) + 1
from   (select 1 from dual connect by level <= 1000),
       (select 1 from dual connect by level <= 1000);
commit;
create index sales.orders_car_ix on sales.orders (car_id);

-- Gather WITHOUT a column group on cars. The optimizer treats make and model as independent and
-- multiplies their selectivities (1/50 x 1/100), estimating ~200 rows when ~10,000 actually match.
begin
  dbms_stats.gather_table_stats('SALES', 'CARS',
    method_opt => 'FOR ALL COLUMNS SIZE 1', cascade => true, no_invalidate => false);
  dbms_stats.gather_table_stats('SALES', 'ORDERS',
    method_opt => 'FOR ALL COLUMNS SIZE 1', cascade => true, no_invalidate => false);
end;
/
exit

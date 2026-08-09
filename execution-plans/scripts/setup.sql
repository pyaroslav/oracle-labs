-- setup.sql — a million-row table with a heavily skewed column, stats WITHOUT a histogram.
-- Run as SYSDBA. Idempotent (safe to re-run).
set echo off feedback off verify off
whenever sqlerror continue
alter session set container = FREEPDB1;

-- clean slate -------------------------------------------------------------------------------------
begin execute immediate 'drop user shop cascade'; exception when others then null; end;
/

-- a schema that owns one big, skewed table --------------------------------------------------------
create user shop identified by "Lab_Passw0rd1" quota unlimited on users;
grant create session, create table to shop;

create table shop.orders (
  id      number       not null,
  status  varchar2(10) not null,
  amount  number       not null,
  filler  varchar2(40)
);

-- 1,000,000 rows. Only 500 are 'OPEN' (0.05%); the rest are 'CLOSED'. Two distinct values, wildly
-- uneven -> exactly the skew an even-distribution assumption gets catastrophically wrong.
insert /*+ append */ into shop.orders (id, status, amount, filler)
select rownum,
       case when rownum <= 500 then 'OPEN' else 'CLOSED' end,
       mod(rownum, 1000) + 1,
       rpad('x', 40, 'x')
from   (select 1 from dual connect by level <= 1000),
       (select 1 from dual connect by level <= 1000);
commit;

create index shop.ord_status_ix on shop.orders (status);
alter table shop.orders add constraint orders_pk primary key (id);

-- Gather stats with NO histogram on status (SIZE 1). Without one, the optimizer assumes the two
-- status values split the table evenly, so 'OPEN' looks like ~500,000 rows instead of 500 -- the
-- misestimate this lab reproduces. no_invalidate=>false so cursors re-parse immediately.
begin
  dbms_stats.gather_table_stats(
    ownname       => 'SHOP',
    tabname       => 'ORDERS',
    method_opt    => 'FOR ALL COLUMNS SIZE 1',
    cascade       => true,
    no_invalidate => false);
end;
/
exit

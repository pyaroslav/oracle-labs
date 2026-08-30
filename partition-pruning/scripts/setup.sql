-- setup.sql — build a range-partitioned table (monthly INTERVAL partitions) and fill it with 1.2M rows,
-- 50,000 per month across 24 months (Jan 2024 .. Dec 2025). Run as SYSDBA. Idempotent (safe to re-run).
--
-- The 80-char filler makes each partition substantial, so a full scan of all partitions is genuinely
-- costly and pruning to one partition is an obvious win in buffer gets.
set echo off feedback off verify off
whenever sqlerror continue
alter session set container = FREEPDB1;

begin execute immediate 'drop user sales cascade'; exception when others then null; end;
/
create user sales identified by "Lab_Passw0rd1" default tablespace users quota unlimited on users;
grant create session, create table to sales;

-- range partition by month, auto-extending (INTERVAL) so we don't hand-write 24 partition clauses.
-- the seed partition holds everything before 2024; the interval creates one partition per month on demand.
create table sales.orders (
  id          number,
  order_date  date not null,
  amount      number,
  filler      varchar2(80)
)
partition by range (order_date)
interval (numtoyminterval(1, 'month'))
( partition p_seed values less than (date '2024-01-01') );

-- 1,200,000 rows: mod(rownum-1,24) picks the month (0..23 -> Jan 2024 .. Dec 2025), evenly 50k per month.
-- the day offset (0..27) keeps every row inside its month, so each monthly partition gets exactly 50,000.
insert /*+ append */ into sales.orders
select rownum,
       add_months(date '2024-01-01', mod(rownum-1, 24)) + mod(rownum, 28),
       mod(rownum, 10000),
       rpad('x', 80, 'x')
from dual connect by level <= 1200000;
commit;

begin
  dbms_stats.gather_table_stats('SALES', 'ORDERS',
    granularity => 'ALL', cascade => true, degree => 4);
end;
/
exit

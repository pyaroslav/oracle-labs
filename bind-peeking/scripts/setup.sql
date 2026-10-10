-- Schema ACS: CUSTOMERS (1,000,000) and ORDERS (200,000) with a heavily skewed STATUS column + a histogram on it.
whenever sqlerror exit failure
alter session set container = FREEPDB1;
begin execute immediate 'drop user acs cascade'; exception when others then null; end;
/
create user acs identified by "Lab_Passw0rd1" quota unlimited on users default tablespace users;
grant create session, create table to acs;
-- the lab user reads its own logical reads and which child cursor it ran
grant select on sys.v_$mystat to acs;
grant select on sys.v_$statname to acs;
grant select on sys.v_$session to acs;

create table acs.customers (
  cust_id  number primary key,
  region   varchar2(20),
  pad      varchar2(200)
);
-- big enough that a full scan of CUSTOMERS is expensive: probing it by key is the right plan for a FEW orders
insert /*+ append */ into acs.customers
select rownum, 'REGION-'||mod(rownum, 12), rpad('c', 200, 'c')
from (select 1 from dual connect by level <= 1000) a, (select 1 from dual connect by level <= 1000) b;
commit;

create table acs.orders (
  order_id number primary key,
  cust_id  number not null,
  status   varchar2(10) not null,
  pad      varchar2(100)
);
-- 1 in 1,000 orders is OPEN (200 rows), the rest are CLOSED (199,800), spread through the table
insert /*+ append */ into acs.orders
select level,
       mod(level * 7919, 1000000) + 1,
       case when mod(level, 1000) = 0 then 'OPEN' else 'CLOSED' end,
       rpad('o', 100, 'o')
from dual connect by level <= 200000;
commit;
create index acs.orders_status_ix on acs.orders(status);

begin
  dbms_stats.gather_table_stats('ACS', 'CUSTOMERS', cascade => true);
  dbms_stats.gather_table_stats('ACS', 'ORDERS', cascade => true,
    method_opt => 'FOR ALL COLUMNS SIZE 1 FOR COLUMNS STATUS SIZE 254');   -- the histogram that makes peeking matter
end;
/
select 'OPEN_ROWS='||count(case when status='OPEN' then 1 end)||' CLOSED_ROWS='||count(case when status='CLOSED' then 1 end) from acs.orders;
select 'HISTOGRAM='||histogram from dba_tab_col_statistics where owner='ACS' and table_name='ORDERS' and column_name='STATUS';
exit

-- setup.sql — a million-row ORDERS table with a heavily skewed, indexed STATUS and a histogram, so a
-- query on the rare value gets the cheap INDEX plan. Run as SYSDBA. Idempotent (safe to re-run).
-- The rows are deliberately WIDE (a filler column) so the table spans many blocks: a full scan is
-- genuinely expensive, which is what makes the index the right choice for ~500 rows — and makes the
-- later regression (histogram gone -> estimate a third of the table -> full scan) unambiguous.
set echo off feedback off verify off
whenever sqlerror continue
alter session set container = FREEPDB1;

-- clean slate -------------------------------------------------------------------------------------
begin execute immediate 'drop user shop cascade'; exception when others then null; end;
/
-- baselines live in the SQL Management Base, not the schema, so dropping the user leaves them behind.
-- Remove any from a previous run so `./run.sh all` is deterministic.
declare
  n number;
begin
  for r in (select sql_handle from dba_sql_plan_baselines where sql_text like '%shop.orders%') loop
    n := dbms_spm.drop_sql_plan_baseline(sql_handle => r.sql_handle);
  end loop;
end;
/

create user shop identified by "Lab_Passw0rd1" quota unlimited on users;
grant create session, create table to shop;

-- 1,000,000 orders. STATUS is skewed: exactly 500 OPEN, ~4,500 CANCELLED, the rest SHIPPED (3 distinct
-- values). The OPEN rows are scattered one every 2,000 rows. The filler widens each row to ~100 bytes so
-- the table is ~12k blocks — a full scan costs real work.
create table shop.orders (
  order_id number       not null,
  status   varchar2(12) not null,
  amount   number       not null,
  filler   varchar2(100)
);
insert /*+ append */ into shop.orders (order_id, status, amount, filler)
select rownum,
       case when mod(rownum, 2000) = 0 then 'OPEN'
            when mod(rownum,  200) = 0 then 'CANCELLED'
            else 'SHIPPED' end,
       mod(rownum, 1000) + 1,
       rpad('x', 80, 'x')
from   (select 1 from dual connect by level <= 1000),
       (select 1 from dual connect by level <= 1000);
commit;
create index shop.orders_status_ix on shop.orders (status);

-- Gather WITH a frequency histogram on STATUS (SIZE 254). The optimizer now knows OPEN is rare (~500),
-- so `WHERE status = 'OPEN'` estimates ~500 rows and picks the index range scan.
begin
  dbms_stats.gather_table_stats('SHOP', 'ORDERS',
    method_opt    => 'FOR ALL COLUMNS SIZE 1 FOR COLUMNS STATUS SIZE 254',
    cascade       => true,
    no_invalidate => false);
end;
/
exit

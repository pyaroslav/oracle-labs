-- Build the workload in FREEPDB1: a 32 MB TEMP tablespace that cannot grow, an app user that sorts in it,
-- ORDERS (200,000 rows) and CUSTOMERS (2,000 rows). SMALLFILE on purpose: this database defaults to BIGFILE
-- (DATABASE_PROPERTIES.DEFAULT_TBS_TYPE), which takes RESIZE instead of ADD TEMPFILE. Smallfile behaves like 19c. Re-runnable.
whenever sqlerror exit failure
alter session set container=FREEPDB1;
begin execute immediate 'drop user ts cascade'; exception when others then if sqlcode != -1918 then raise; end if; end;
/
begin execute immediate 'drop tablespace temp_small including contents and datafiles'; exception when others then if sqlcode != -959 then raise; end if; end;
/
create smallfile temporary tablespace temp_small tempfile '/opt/oracle/oradata/FREE/FREEPDB1/temp_small01.dbf' size 32m autoextend off;
create user ts identified by "Ts_Passw0rd1" quota unlimited on users temporary tablespace temp_small;
grant create session, create table to ts;
create table ts.customers (customer_id number primary key, name varchar2(40), region varchar2(10)) tablespace users;
insert into ts.customers select level, 'Customer ' || level, 'R' || mod(level, 8) from dual connect by level <= 2000;
create table ts.orders (order_id number primary key, customer_id number not null, amount number(10,2),
                        status varchar2(10), note varchar2(60)) tablespace users;
insert /*+ append */ into ts.orders
  select level, mod(level, 2000) + 1, round(dbms_random.value(1, 5000), 2),
         case mod(level, 4) when 0 then 'OPEN' else 'CLOSED' end, rpad('n', 60, 'n')
  from dual connect by level <= 200000;
commit;
exec dbms_stats.gather_schema_stats('TS')
exit

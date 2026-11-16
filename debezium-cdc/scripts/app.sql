-- APP schema: three copies of one table, differing only in table-level supplemental logging.
--   ORDERS      (ALL) COLUMNS  -- what the Debezium documentation asks for
--   ORDERS_PK   (PRIMARY KEY) COLUMNS
--   ORDERS_MIN  none (only the database-level minimal supplemental logging)
whenever sqlerror continue
set heading off feedback off pages 0
alter session set container = FREEPDB1;
begin  -- end any session left from an earlier run (an open transaction would pin the next run's connector)
  for s in (select sid, serial# from v$session where username = 'APP') loop
    execute immediate 'alter system kill session ''' || s.sid || ',' || s.serial# || ''' immediate';
  end loop;
end;
/
drop user app cascade;
create user app identified by App_Passw0rd1 quota unlimited on users;
grant create session, create table to app;
begin
  for t in (select column_value n from table(sys.odcivarchar2list('ORDERS','ORDERS_PK','ORDERS_MIN'))) loop
    execute immediate 'create table app.' || t.n || ' (
      id       number(10) primary key,
      customer varchar2(40) not null,
      amount   number(10,2),
      qty      number,
      status   varchar2(12),
      note     clob)';
    execute immediate 'insert into app.' || t.n || q'[ values (1, 'ACME',   100.50, 3,           'NEW', 'first order')]';
    execute immediate 'insert into app.' || t.n || q'[ values (2, 'GLOBEX', 250.00, 1234567.891, 'NEW', null)]';
  end loop;
  commit;
end;
/
alter table app.orders    add supplemental log data (all) columns;
alter table app.orders_pk add supplemental log data (primary key) columns;
select 'TABLES=' || count(*) from dba_tables where owner = 'APP';
select 'LOGGROUPS=' || listagg(table_name || ':' || replace(log_group_type, ' ', '_'), ',') within group (order by table_name)
from dba_log_groups where owner = 'APP';
exit

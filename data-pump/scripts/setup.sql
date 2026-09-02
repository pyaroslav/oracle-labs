-- setup.sql — build the DPSHOP schema of KNOWN size + a Data Pump DIRECTORY object. Run as SYSDBA.
-- Idempotent (safe to re-run). The exact row counts (5,000 customers, 20,000 orders) are what the drills
-- assert survive the export/import round trip and the remap.
set echo off feedback off verify off
whenever sqlerror continue
alter session set container = FREEPDB1;

-- clean slate: the source schema and the two import targets used by the drills
begin execute immediate 'drop user dpshop cascade';  exception when others then null; end;
/
begin execute immediate 'drop user dpclone cascade'; exception when others then null; end;
/
begin execute immediate 'drop user dponly cascade';  exception when others then null; end;
/

-- Data Pump reads/writes dump files through a DIRECTORY object pointing at a real path in the container.
create or replace directory dp_dir as '/opt/oracle/dpdump';
grant read, write on directory dp_dir to system;

create user dpshop identified by "Lab_Passw0rd1" default tablespace users quota unlimited on users;
grant create session, create table to dpshop;

create table dpshop.customers (
  id number primary key, name varchar2(40), city varchar2(30)
);
create table dpshop.orders (
  id number primary key, customer_id number, amount number, status varchar2(12)
);

insert into dpshop.customers
  select rownum, 'Customer_'||lpad(rownum,5,'0'), 'City_'||mod(rownum,50)
  from dual connect by level <= 5000;
insert into dpshop.orders
  select rownum, mod(rownum,5000)+1, mod(rownum,10000), decode(mod(rownum,3),0,'OPEN',1,'SHIPPED','CANCELLED')
  from dual connect by level <= 20000;
commit;

grant read, write on directory dp_dir to dpshop;
exit

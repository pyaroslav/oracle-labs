-- setup.sql — run as SYSDBA. Source schema SHOP: ORDERS keyed by ORDER_SEQ, 9,000 orders taken so far.
-- Drops any previous target (NEWSHOP) and creates the Data Pump directory. Demo data is generic and invented.
set echo off feedback off verify off heading off pagesize 0
alter session set container = FREEPDB1;
whenever sqlerror continue
drop user shop cascade;
drop user newshop cascade;
whenever sqlerror exit failure
create or replace directory dp_dir as '/opt/oracle/dpdump';
grant read, write on directory dp_dir to system;
create user shop identified by "Shop_Passw0rd1" default tablespace users quota unlimited on users;
grant create session, create table, create sequence to shop;
-- NOCACHE keeps the lab numbers exact (see README: with CACHE the exported START WITH is the cache high-water).
create sequence shop.order_seq start with 1 increment by 1 nocache;
create table shop.orders (id number primary key, item varchar2(30), created date);
begin
  for i in 1 .. 9000 loop
    insert into shop.orders values (shop.order_seq.nextval, 'item ' || mod(i, 97), date '2026-09-01' + mod(i, 30));
  end loop;
  commit;
end;
/
exit

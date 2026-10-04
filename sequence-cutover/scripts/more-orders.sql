-- more-orders.sql — run as SYSDBA. The source keeps taking orders after the initial load: 1,000 more.
set echo off feedback off verify off heading off pagesize 0
alter session set container = FREEPDB1;
whenever sqlerror exit failure
begin
  for i in 1 .. 1000 loop
    insert into shop.orders values (shop.order_seq.nextval, 'late item ' || mod(i, 97), date '2026-10-01');
  end loop;
  commit;
end;
/
exit

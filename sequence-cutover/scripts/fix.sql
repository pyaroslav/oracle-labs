-- fix.sql — run as SYSDBA. Move every lagging sequence past the highest existing key.
-- RESTART START WITH (18c+) resets the sequence in place; no drop/recreate, grants and dependents stay intact.
set echo off feedback off verify off heading off pagesize 0
alter session set container = FREEPDB1;
whenever sqlerror exit failure
declare
  mx number;
begin
  select nvl(max(id), 0) into mx from newshop.orders;
  execute immediate 'alter sequence newshop.order_seq restart start with ' || (mx + 1);
end;
/
exit

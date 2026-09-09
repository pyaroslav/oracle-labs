-- workload.sql — run as APPUSER while the capture is enabled. This exercises a SMALL subset of everything
-- APPUSER was granted: it logs in (CREATE SESSION), reads ONE table it has an explicit object grant on
-- (SELECT on PAOWN.CUSTOMERS — note it does NOT use SELECT ANY TABLE), and creates one table in its own
-- schema (CREATE TABLE). It never creates a view, a procedure, a sequence, or a synonym; never touches
-- another schema's objects (no CREATE/DROP/ALTER ANY TABLE); and never reads PAOWN.ORDERS. Those become
-- the "unused" pile the analyze drill reports.
set echo off feedback off verify off
whenever sqlerror continue
select count(*) from paown.customers;
begin execute immediate 'drop table appuser.scratch'; exception when others then null; end;
/
create table appuser.scratch (id number);
insert into appuser.scratch values (1);
commit;
exit

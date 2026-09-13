-- meta.sql — ground-truth facts for the setup drill, read as SYSDBA: row count, the status skew, and that
-- both indexes exist. NOTE: prompt markers must NOT end in '-' (SQL*Plus treats a trailing hyphen as a line
-- continuation).
set echo off feedback off verify off heading off pagesize 0 linesize 300 trimspool on
alter session set container = FREEPDB1;

prompt >>>SIGNALS
select 'ROWS='||count(*)    from shop.orders;
select 'SHIPPED='||count(*) from shop.orders where status = 'SHIPPED';
select 'PENDING='||count(*) from shop.orders where status = 'PENDING';
select 'IDX='||count(*)     from dba_indexes where owner = 'SHOP' and table_name = 'ORDERS';
prompt >>>ENDSIGNALS
exit

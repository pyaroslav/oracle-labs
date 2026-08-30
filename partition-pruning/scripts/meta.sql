-- meta.sql — emit machine-readable facts for run.sh: how many partitions the table has and its row count.
-- Run as SYSDBA. NOTE: prompt markers must NOT end in '-' (SQL*Plus treats a trailing hyphen as a line
-- continuation).
set echo off feedback off verify off heading off pagesize 0 linesize 200 trimspool on
alter session set container = FREEPDB1;

prompt >>>SIGNALS
select 'PARTS='||count(*) from dba_tab_partitions where table_owner='SALES' and table_name='ORDERS';
select 'ROWS='||count(*)  from sales.orders;
prompt >>>ENDSIGNALS
exit

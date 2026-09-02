-- counts.sql — emit row counts + table list for a schema, so run.sh can assert the round trip / remap.
-- Called with a SQL*Plus define piped ahead:  { echo "define SCHEMA=DPSHOP"; cat counts.sql; } | run_sys
-- Run as SYSDBA. NOTE: markers must NOT end in '-' (SQL*Plus treats a trailing hyphen as a continuation).
set echo off feedback off verify off heading off pagesize 0 linesize 200 trimspool on
whenever sqlerror continue
alter session set container = FREEPDB1;

prompt >>>SIGNALS
select 'TABLES='||listagg(table_name, ',') within group (order by table_name)
  from dba_tables where owner = upper('&SCHEMA');
select 'CUST='||count(*) from &SCHEMA..customers;
select 'ORD='||count(*)  from &SCHEMA..orders;
prompt >>>ENDSIGNALS
exit

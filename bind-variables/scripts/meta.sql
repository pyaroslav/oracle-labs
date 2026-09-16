-- meta.sql — ground-truth facts for the setup drill, read as SYSDBA: the table exists and holds 1,000 rows.
set echo off feedback off verify off heading off pagesize 0 linesize 200 trimspool on
alter session set container = FREEPDB1;
prompt >>>SIGNALS
select 'ROWS='||count(*) from bindlab.widgets;
select 'TAB='||count(*)  from dba_tables where owner = 'BINDLAB' and table_name = 'WIDGETS';
prompt >>>ENDSIGNALS
exit

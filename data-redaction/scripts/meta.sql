-- meta.sql — emit machine-readable facts for run.sh: the REAL datafile path of the RED_DATA tablespace
-- (so run.sh greps the actual file), the row count, and how many columns the redaction policy covers.
-- Run as SYSDBA. NOTE: prompt markers must NOT end in '-' (SQL*Plus treats a trailing hyphen as a line
-- continuation).
set echo off feedback off verify off heading off pagesize 0 linesize 300 trimspool on
alter session set container = FREEPDB1;

prompt >>>SIGNALS
select 'FILE_RED='  ||file_name from dba_data_files where tablespace_name = 'RED_DATA';
select 'ROWS='      ||count(*) from redown.customers;
select 'REDACT_COLS='||count(*) from redaction_columns
  where object_owner = 'REDOWN' and object_name = 'CUSTOMERS';
prompt >>>ENDSIGNALS
exit

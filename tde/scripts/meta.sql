-- meta.sql — emit machine-readable facts for run.sh: whether each tablespace is encrypted, the row
-- counts, and the REAL datafile paths (so run.sh greps the actual files, not a hard-coded guess).
-- Run as SYSDBA. NOTE: prompt markers must NOT end in '-' (SQL*Plus treats a trailing hyphen as a
-- line continuation).
set echo off feedback off verify off heading off pagesize 0 linesize 300 trimspool on
alter session set container = FREEPDB1;

prompt >>>SIGNALS
select 'ENC_TDE_ENC='   ||encrypted from dba_tablespaces where tablespace_name = 'TDE_ENC';
select 'ENC_TDE_PLAIN=' ||encrypted from dba_tablespaces where tablespace_name = 'TDE_PLAIN';
select 'ROWS_ENC='  ||count(*) from app.secrets_enc;
select 'ROWS_PLAIN='||count(*) from app.secrets_plain;
select 'FILE_ENC='  ||file_name from dba_data_files where tablespace_name = 'TDE_ENC';
select 'FILE_PLAIN='||file_name from dba_data_files where tablespace_name = 'TDE_PLAIN';
prompt >>>ENDSIGNALS
exit

-- meta.sql -- ground-truth facts after setup, read as SYSDBA in the PDB: the row count and how many rows hold
-- non-ASCII characters (LENGTHB > LENGTH means the value took more bytes than characters, i.e. it is multibyte
-- UTF-8). Marker lines never end in a hyphen.
set echo off feedback off verify off heading off pagesize 0 linesize 200 trimspool on define off
alter session set container = FREEPDB1;
prompt >>>SIGNALS
select 'ROWS='||count(*) from csmig.customers;
select 'MULTIBYTE='||count(*) from csmig.customers where lengthb(name) > length(name);
prompt >>>ENDSIGNALS
exit

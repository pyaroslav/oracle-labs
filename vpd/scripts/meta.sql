-- meta.sql — ground-truth facts for run.sh, read as SYSDBA. SYS is exempt from VPD, so it sees the WHOLE
-- table: the true total and per-region counts, plus whether the policy is enabled on VPDOWN.ORDERS.
-- NOTE: prompt markers must NOT end in '-' (SQL*Plus treats a trailing hyphen as a line continuation).
set echo off feedback off verify off heading off pagesize 0 linesize 300 trimspool on
alter session set container = FREEPDB1;

prompt >>>SIGNALS
select 'TOTAL='||count(*) from vpdown.orders;
select 'EAST='||count(*)  from vpdown.orders where region = 'EAST';
select 'WEST='||count(*)  from vpdown.orders where region = 'WEST';
select 'POLICIES='||count(*) from dba_policies
  where object_owner = 'VPDOWN' and object_name = 'ORDERS' and enable = 'YES';
prompt >>>ENDSIGNALS
exit

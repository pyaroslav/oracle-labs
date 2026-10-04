-- state.sql — run as SYSDBA. Ground truth for the drills: rows and MAX(id) on both sides, and where each
-- ORDER_SEQ will hand out its next value (LAST_NUMBER is the next number not yet cached).
set echo off feedback off verify off heading off pagesize 0 linesize 200 trimspool on
alter session set container = FREEPDB1;
prompt >>>SIGNALS
select 'SRC_ROWS='||count(*)||chr(10)||'SRC_MAX='||max(id) from shop.orders;
select 'TGT_ROWS='||count(*)||chr(10)||'TGT_MAX='||max(id) from newshop.orders;
select 'TGT_SEQ_NEXT='||last_number from dba_sequences where sequence_owner = 'NEWSHOP' and sequence_name = 'ORDER_SEQ';
prompt >>>ENDSIGNALS
exit

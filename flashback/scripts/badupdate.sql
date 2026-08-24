-- badupdate.sql — reverse a committed, WHERE-less UPDATE with FLASHBACK TABLE ... TO SCN.
-- Run as LABUSER in FREEPDB1. Emits ZEROED_AFTER_UPDATE / ZEROED_AFTER_FLASHBACK / ROWS for run.sh.
-- Requires ROW MOVEMENT on the table (set in setup.sql) and the table to be old enough (run.sh waits).
set echo off feedback off verify off heading off pagesize 0 linesize 200 trimspool on

-- capture a precise marker (SCN) at the moment *before* the mistake
column v_scn new_value V_SCN noprint
select dbms_flashback.get_system_change_number as v_scn from dual;

-- the mistake: a committed UPDATE with no WHERE clause wipes every balance to zero
update accounts set balance = 0;
commit;
select 'ZEROED_AFTER_UPDATE='||count(*) from accounts where balance = 0;

-- recovery: rewind just this table to the captured SCN (rows are physically re-inserted -> row movement)
flashback table accounts to scn &V_SCN;
select 'ZEROED_AFTER_FLASHBACK='||count(*) from accounts where balance = 0;
select 'ROWS='||count(*) from accounts;
exit

-- ============================================================================
-- DRILL: 'direct path read'  (User I/O)  — multiblock reads into the PGA.
-- Run as SYS (sqlplus -s -L "/ as sysdba").
--
-- Here the blocks go straight from the datafile into the session's private PGA,
-- BYPASSING the SGA buffer cache. Since 11g a serial full scan of a "large"
-- segment (roughly > 5x _small_table_threshold) does this automatically, and
-- parallel-query slaves ALWAYS read their granules direct. Because the I/O is
-- async, the wait COUNT does not equal the number of read requests.
--
-- We make it deterministic two ways and run both:
--   PRIMARY  : ALTER SESSION SET "_serial_direct_read" = ALWAYS  (serial, always direct)
--   FALLBACK : a PARALLEL full scan (PX slaves always read direct), in case the
--              underscore param is unavailable in your build.
--
-- Shape: (a) stage = flush + _serial_direct_read=ALWAYS ; (b) workload = FULL scan ;
--        (c) signature = v$session_event for THIS session, time_waited_micro DESC.
-- ============================================================================
set echo off feedback off verify off pagesize 100 linesize 160 serveroutput on

alter session set container = FREEPDB1;

column sid new_value v_sid noprint
select sys_context('USERENV','SID') as sid from dual;

column base_waits new_value v_base_waits noprint
column base_micro new_value v_base_micro noprint
select nvl(max(total_waits),0)       as base_waits,
       nvl(max(time_waited_micro),0) as base_micro
from   v$session_event
where  sid = &v_sid
  and  event = 'direct path read';

-- ---- (a) SET THE STAGE -----------------------------------------------------
-- _serial_direct_read=ALWAYS guarantees the serial scan uses direct path even if
-- the size heuristic is borderline. Hidden parameter: throwaway lab only.
prompt >> Forcing direct-path scans (_serial_direct_read=ALWAYS) and flushing the cache...
alter session set "_serial_direct_read" = always;
alter system flush buffer_cache;

-- ---- (b) WORKLOAD ----------------------------------------------------------
-- Pass 1: serial FULL scan -> 'direct path read' (into PGA).
-- Pass 2: PARALLEL full scan -> PX slaves also read direct (fallback proof that
-- does not rely on the underscore parameter at all).
prompt >> Workload: serial FULL scan of t_dpr (~150 MB), then a PARALLEL scan...
declare
  n number;
begin
  select /*+ full(t) */ count(*) into n from labuser.t_dpr t where pad like '%qqq%';
  execute immediate 'alter system flush buffer_cache';
  select /*+ full(t) parallel(t,4) */ count(*) into n from labuser.t_dpr t where pad like '%qqq%';
end;
/

-- ---- proof it bypassed the cache -------------------------------------------
prompt
prompt --- Proof: physical reads DIRECT should rise (blocks went to the PGA) ----
column name  format a26
column value format 999,999,990
select sn.name, ms.value
from   v$mystat ms
join   v$statname sn on sn.statistic# = ms.statistic#
where  sn.name in ('physical reads cache','physical reads direct');

-- ---- (c) SIGNATURE ---------------------------------------------------------
-- NOTE: the PARALLEL pass does its direct reads in PX SLAVE sessions, whose
-- waits land on the slaves' SIDs, not ours. The serial pass above credits
-- 'direct path read' to THIS session, which is what the delta below captures.
prompt
prompt ============================================================
prompt  WAIT SIGNATURE for this session (top events by time waited)
prompt ============================================================
column event             format a32
column wait_class        format a12
column total_waits       format 999,999,990
column time_waited_micro format 999,999,999,990
column avg_ms            format 9,990.000
select se.event,
       en.wait_class,
       se.total_waits,
       se.time_waited_micro,
       round(se.time_waited_micro/nullif(se.total_waits,0)/1000, 3) as avg_ms
from   v$session_event se
join   v$event_name    en on en.name = se.event
where  se.sid = &v_sid
  and  en.wait_class <> 'Idle'
order  by se.time_waited_micro desc
fetch  first 8 rows only;

prompt
prompt --- This drill''s target event, as a BEFORE -> AFTER delta (serial pass) ----
column d_waits format 999,999,990
column d_micro format 999,999,999,990
select 'direct path read' as event,
       (total_waits - &v_base_waits)              as d_waits,
       (time_waited_micro - &v_base_micro)         as d_micro,
       round((time_waited_micro - &v_base_micro)/1000, 1) as d_ms
from   v$session_event
where  sid = &v_sid
  and  event = 'direct path read';

prompt
prompt Read it: 'physical reads direct' rose (blocks went to the PGA, not the SGA).
prompt The wait count is LOWER than the read-request count because direct path I/O
prompt is asynchronous. This is normal for large serial/parallel scans -- a bigger
prompt buffer cache would NOT route such a scan through the SGA. (PX-slave direct
prompt reads show on the slaves' SIDs, so they are not in this session's totals.)
exit


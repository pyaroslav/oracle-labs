-- ============================================================================
-- DRILL: 'db file scattered read'  (User I/O)  — buffered MULTIBLOCK reads.
-- Run as SYS (sqlplus -s -L "/ as sysdba").
--
-- A full table scan reads many blocks per OS call (up to
-- db_file_multiblock_read_count) INTO the SGA buffer cache; "scattered" because
-- the contiguous run of disk blocks lands in non-contiguous cache buffers
-- (P3 > 1, distinguishing it from the single-block sequential read).
--
-- THE GOTCHA THIS DRILL EXISTS TO BEAT: on 11g+ a large serial full scan
-- usually goes "direct path read" (into the PGA, bypassing the cache) instead.
-- We force the scan to stay buffered with:
--     ALTER SESSION SET "_serial_direct_read" = NEVER
-- so we deterministically get 'db file scattered read', not 'direct path read'.
--
-- Shape: (a) stage = flush + _serial_direct_read=NEVER ; (b) workload = FULL scan ;
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
  and  event = 'db file scattered read';

-- ---- (a) SET THE STAGE -----------------------------------------------------
-- _serial_direct_read=NEVER  -> serial scans go through the buffer cache, so the
-- multiblock reads surface as 'db file scattered read' (not 'direct path read').
-- It is a hidden parameter: throwaway lab only, never production.
prompt >> Forcing buffered scans (_serial_direct_read=NEVER) and flushing the cache...
alter session set "_serial_direct_read" = never;
alter system flush buffer_cache;

-- ---- (b) WORKLOAD: full table scan -> multiblock buffered reads -------------
-- FULL hint guarantees TABLE ACCESS FULL; the predicate matches nothing so the
-- whole ~150 MB segment is scanned. Two passes (flush between) for a clean count.
prompt >> Workload: FULL scan of t_scat (~150 MB) through the buffer cache...
declare
  n number;
begin
  select /*+ full(t) */ count(*) into n from labuser.t_scat t where pad like '%qqq%';
  execute immediate 'alter system flush buffer_cache';
  select /*+ full(t) */ count(*) into n from labuser.t_scat t where pad like '%qqq%';
end;
/

-- ---- proof it went through the cache (not direct path) ----------------------
prompt
prompt --- Proof: physical reads CACHE should rise, physical reads DIRECT should not ---
column name  format a26
column value format 999,999,990
select sn.name, ms.value
from   v$mystat ms
join   v$statname sn on sn.statistic# = ms.statistic#
where  sn.name in ('physical reads cache','physical reads direct');

-- ---- (c) SIGNATURE ---------------------------------------------------------
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
prompt --- This drill''s target event, as a BEFORE -> AFTER delta -----------------
column d_waits format 999,999,990
column d_micro format 999,999,999,990
select 'db file scattered read' as event,
       (total_waits - &v_base_waits)              as d_waits,
       (time_waited_micro - &v_base_micro)         as d_micro,
       round((time_waited_micro - &v_base_micro)/1000, 1) as d_ms
from   v$session_event
where  sid = &v_sid
  and  event = 'db file scattered read';

prompt
prompt Read it: each wait moved many blocks (P3 = multiblock, up to
prompt db_file_multiblock_read_count), so total_waits is far smaller than the block
prompt count. 'physical reads cache' rose (it went through the SGA). Drop the
prompt _serial_direct_read=NEVER line and re-run to watch this flip to 'direct path read'.
exit


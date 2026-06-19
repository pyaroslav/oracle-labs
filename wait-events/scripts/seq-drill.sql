-- ============================================================================
-- DRILL: 'db file sequential read'  (User I/O)  — SINGLE-block reads.
-- Run as SYS (sqlplus -s -L "/ as sysdba").
--
-- Despite the name, this is NOT a multiblock scan. It is the synchronous,
-- one-block-at-a-time read that index access produces: each uncached index
-- leaf block and each TABLE ACCESS BY INDEX ROWID block fetch is one
-- 'db file sequential read' with P3 (blocks) = 1.
--
-- Shape of every drill:
--   (a) SET THE STAGE  : ALTER SYSTEM FLUSH BUFFER_CACHE  -> next access is physical
--   (b) WORKLOAD       : index range scan + rowid lookups so the reads are single-block
--   (c) SIGNATURE      : v$session_event for THIS session, time_waited_micro DESC,
--                        printed as a before/after delta so cause -> signature is visible.
-- ============================================================================
set echo off feedback off verify off pagesize 100 linesize 160 serveroutput on

alter session set container = FREEPDB1;

-- Capture this session's SID once; everything below filters on it.
column sid new_value v_sid noprint
select sys_context('USERENV','SID') as sid from dual;

-- ---- BEFORE snapshot of the target event ----------------------------------
-- v$session_event is cumulative per session since logon, so we record the
-- baseline first and report the delta the workload produces.
column base_waits new_value v_base_waits noprint
column base_micro new_value v_base_micro noprint
select nvl(max(total_waits),0)       as base_waits,
       nvl(max(time_waited_micro),0) as base_micro
from   v$session_event
where  sid = &v_sid
  and  event = 'db file sequential read';

-- ---- (a) SET THE STAGE -----------------------------------------------------
prompt >> Flushing the buffer cache so the next access must read from disk...
alter system flush buffer_cache;

-- ---- (b) WORKLOAD: force index access -> single-block reads -----------------
-- The INDEX hint guarantees an index range scan; the SUM(LENGTH(pad)) forces
-- the rowid table lookups (each visits a table block = one single-block read).
prompt >> Workload: index range scan + rowid lookups over 200k rows (single-block reads)...
declare
  n number;
begin
  select /*+ index(t t_seq_id_ix) */ sum(length(pad))
  into   n
  from   labuser.t_seq t
  where  id between 1 and 200000;
end;
/

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
column event format a32
column d_waits format 999,999,990
column d_micro format 999,999,999,990
select 'db file sequential read' as event,
       (total_waits - &v_base_waits)             as d_waits,
       (time_waited_micro - &v_base_micro)        as d_micro,
       round((time_waited_micro - &v_base_micro)/1000, 1) as d_ms
from   v$session_event
where  sid = &v_sid
  and  event = 'db file sequential read';

prompt
prompt Read it: total_waits jumped by ~one per uncached index leaf + rowid table
prompt block (P3=1, single-block). On fast local disk avg_ms is tiny; on real
prompt storage these same single-block reads become the top User I/O event. If you
prompt see NO delta, the blocks were already cached -> the FLUSH is what makes it physical.
exit


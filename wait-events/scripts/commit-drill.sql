-- ============================================================================
-- DRILL: 'log file sync'  (Commit)  — the per-commit durability wait.
-- Run as SYS (sqlplus -s -L "/ as sysdba").
--
-- On COMMIT the session posts LGWR to flush its redo to the online log and
-- sleeps in 'log file sync' until LGWR posts back that the redo is durable.
-- The wait time = LGWR pickup + the physical write ('log file parallel write')
-- + the post/wakeup round-trip. Row-by-row COMMIT in a loop forces one
-- synchronous LGWR write+post per iteration -- the classic LFS generator.
--
-- The contrast that teaches the lesson: 'log file parallel write' (LGWR's pure
-- I/O slice, System I/O class) rises FAR LESS than the commit count, because
-- group commit batches many foreground commits per physical write. So
-- avg LFS > avg LFPW even on fast local disk -> LFS is about commit FREQUENCY
-- and LGWR scheduling, not just storage speed.
--
-- Shape: (a) stage = none beyond a scratch table (no flush needed -- this is a
--        redo/commit event, not a buffer-cache one) ; (b) workload = commit loop ;
--        (c) signature = v$session_event for THIS session, time_waited_micro DESC.
-- ============================================================================
set echo off feedback off verify off pagesize 100 linesize 160 serveroutput on

alter session set container = FREEPDB1;

column sid new_value v_sid noprint
select sys_context('USERENV','SID') as sid from dual;

-- ---- BEFORE snapshot: capture BOTH events so the contrast is visible --------
-- (log file parallel write is an LGWR/background event; a foreground session
--  does not post it, so it usually shows zero on THIS sid -- which is the point.)
column base_lfs_w new_value v_base_lfs_w noprint
column base_lfs_m new_value v_base_lfs_m noprint
select nvl(max(case when event='log file sync' then total_waits end),0)       as base_lfs_w,
       nvl(max(case when event='log file sync' then time_waited_micro end),0) as base_lfs_m
from   v$session_event
where  sid = &v_sid
  and  event = 'log file sync';

-- ---- (a) SET THE STAGE -----------------------------------------------------
prompt >> Clearing the scratch table...
truncate table labuser.lfs_demo;

-- ---- (b) WORKLOAD: row-by-row INSERT + COMMIT, many iterations -------------
-- The COMMIT *inside* the loop is what makes this 'log file sync': each commit
-- is a synchronous LGWR write + post. 50,000 iterations -> ~50,000 LFS waits.
prompt >> Workload: 50,000 x (single-row INSERT + COMMIT) -- one LFS wait per commit...
declare
begin
  for i in 1 .. 50000 loop
    insert into labuser.lfs_demo values (i, rpad('x', 100, 'x'));
    commit;                       -- <-- the line that generates 'log file sync'
  end loop;
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
prompt --- Target event delta, and the group-commit contrast (instance-wide LFPW) ---
column event format a26
column waits format 999,999,990
column ms    format 999,999,990.0
-- This session's 'log file sync' delta: ~50,000 waits, one per commit.
select 'log file sync (this sid)' as event,
       (total_waits - &v_base_lfs_w)               as waits,
       round((time_waited_micro - &v_base_lfs_m)/1000, 1) as ms
from   v$session_event
where  sid = &v_sid
  and  event = 'log file sync'
union all
-- Instance-wide LGWR writes: rises far LESS than 50,000 thanks to group commit.
select 'log file parallel write (sys)' as event,
       total_waits                  as waits,
       round(time_waited_micro/1000, 1) as ms
from   v$system_event
where  event = 'log file parallel write';

prompt
prompt Read it: ~50,000 'log file sync' waits (one per COMMIT), while instance-wide
prompt 'log file parallel write' counts FAR fewer writes -- group commit batches many
prompt foreground commits per physical write, so avg LFS > avg LFPW. The fix for high
prompt LFS is almost always BATCHING commits, not faster disk. To prove that: move the
prompt COMMIT outside the loop and re-run -- LFS waits collapse to ~1 though row count
prompt is unchanged, showing commit FREQUENCY (not volume) drives the event.
exit


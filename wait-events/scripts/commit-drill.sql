-- ============================================================================
-- DRILL: 'log file sync'  (Commit)  — the per-commit durability wait.
-- Run as SYS via `./run.sh drill-commit` (run.sh generates the client-side
-- workload file and defines &lfs_n / &lfs_workload before this script runs).
--
-- On COMMIT the session posts LGWR to flush its redo to the online log and
-- sleeps in 'log file sync' until LGWR posts back that the redo is durable.
-- The wait time = LGWR pickup + the physical write ('log file parallel write')
-- + the post/wakeup round-trip.
--
-- WHY THE WORKLOAD IS CLIENT-SIDE: an application that commits per row issues
-- each COMMIT as its own call from the client. That is what this drill does --
-- a generated SQL*Plus script of N x (INSERT; COMMIT;) run in ONE session, so
-- every commit is a synchronous LGWR write+post -> one 'log file sync' each.
-- A COMMIT inside a PL/SQL loop does NOT behave that way: PL/SQL's commit-time
-- optimization (asynchronous commit inside the block, one sync wait at the
-- end of the call) means the session waits ~once. Part (d) runs exactly that
-- loop with the same N so you can see the difference on the same session.
--
-- The contrast with 'log file parallel write' (LGWR's pure I/O slice, System
-- I/O class, instance-wide): with ONE committing session there is nothing for
-- group commit to batch, so LGWR writes ~once per commit too, and avg LFS sits
-- a little above avg LFPW -- the gap is the post/wakeup round-trip. The wait
-- count tracks commit FREQUENCY; the cure is fewer commits, not faster disk.
--
-- Shape: (a) stage = truncate a scratch table (no flush needed -- this is a
--        redo/commit event, not a buffer-cache one) ; (b) workload = N client
--        commits ; (c) signature = v$session_event for THIS session, measured
--        before -> after ; (d) contrast = same N commits inside PL/SQL.
-- ============================================================================
set echo off feedback off verify off pagesize 100 linesize 160 serveroutput on

alter session set container = FREEPDB1;

column sid new_value v_sid noprint
select sys_context('USERENV','SID') as sid from dual;

-- ---- (a) SET THE STAGE -----------------------------------------------------
prompt >> Clearing the scratch table...
truncate table labuser.lfs_demo;

-- ---- BEFORE snapshot (after the TRUNCATE, whose recursive commits would
--      otherwise pad the count): this session's LFS + instance-wide LGWR writes.
-- 'log file parallel write' is an LGWR (CDB-level) event: from inside a PDB,
-- v$system_event hides it, so we read it from CDB$ROOT and switch straight back.
column base_lfs_w  new_value v_base_lfs_w  noprint
column base_lfs_m  new_value v_base_lfs_m  noprint
column base_lfpw_w new_value v_base_lfpw_w noprint
column base_lfpw_m new_value v_base_lfpw_m noprint
select nvl(max(total_waits),0)       as base_lfs_w,
       nvl(max(time_waited_micro),0) as base_lfs_m
from   v$session_event
where  sid = &v_sid and event = 'log file sync';
alter session set container = CDB$ROOT;
select nvl(max(total_waits),0)       as base_lfpw_w,
       nvl(max(time_waited_micro),0) as base_lfpw_m
from   v$system_event
where  event = 'log file parallel write';
alter session set container = FREEPDB1;

-- ---- (b) WORKLOAD: N client-side single-row INSERT + COMMIT calls ----------
prompt >> Workload: &lfs_n x (single-row INSERT; COMMIT;) sent from the client, one session...
@&lfs_workload

-- ---- AFTER snapshot (taken before anything else commits) --------------------
column lfs_w   new_value v_lfs_w   noprint
column lfs_m   new_value v_lfs_m   noprint
column lfpw_w  new_value v_lfpw_w  noprint
column lfpw_m  new_value v_lfpw_m  noprint
select nvl(max(total_waits),0) - &v_base_lfs_w       as lfs_w,
       nvl(max(time_waited_micro),0) - &v_base_lfs_m as lfs_m
from   v$session_event
where  sid = &v_sid and event = 'log file sync';
alter session set container = CDB$ROOT;
select nvl(max(total_waits),0) - &v_base_lfpw_w       as lfpw_w,
       nvl(max(time_waited_micro),0) - &v_base_lfpw_m as lfpw_m
from   v$system_event
where  event = 'log file parallel write';
alter session set container = FREEPDB1;

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
prompt --- Measured BEFORE -> AFTER delta for the &lfs_n client commits ===
column event  format a34
column waits  format 999,999,990
column ms     format 999,999,990.0
column avg_ms format 9,990.000
select 'log file sync (this sid)' as event,
       &v_lfs_w as waits,
       round(&v_lfs_m/1000, 1) as ms,
       round(&v_lfs_m/nullif(&v_lfs_w,0)/1000, 3) as avg_ms
from   dual
union all
select 'log file parallel write (instance)',
       &v_lfpw_w,
       round(&v_lfpw_m/1000, 1),
       round(&v_lfpw_m/nullif(&v_lfpw_w,0)/1000, 3)
from   dual;

-- ---- (d) CONTRAST: the same N commits inside a PL/SQL loop -----------------
prompt
prompt >> Contrast: the same &lfs_n x (INSERT + COMMIT) inside ONE PL/SQL block...
column plsql_base_w new_value v_plsql_base_w noprint
select nvl(max(total_waits),0) as plsql_base_w
from   v$session_event where sid = &v_sid and event = 'log file sync';
begin
  for i in 1 .. &lfs_n loop
    insert into labuser.lfs_demo values (-i, rpad('x', 100, 'x'));
    commit;      -- asynchronous inside PL/SQL: one sync wait at the end of the call
  end loop;
end;
/
column plsql_w new_value v_plsql_w noprint
select nvl(max(total_waits),0) - &v_plsql_base_w as plsql_w
from   v$session_event where sid = &v_sid and event = 'log file sync';

-- ---- Measured summary (machine-readable line is checked by run.sh) ---------
prompt
set heading off
select 'LFS_SIGNAL n=&lfs_n client_waits=' || &v_lfs_w
       || ' client_avg_ms=' || to_char(round(&v_lfs_m/nullif(&v_lfs_w,0)/1000, 3), 'FM9990.000')
       || ' lfpw_writes=' || &v_lfpw_w
       || ' plsql_waits=' || &v_plsql_w
from dual;
select 'Read it: ' || to_char(&lfs_n, 'FM999,999') || ' client-side COMMITs produced '
       || to_char(&v_lfs_w, 'FM999,999') || ' ''log file sync'' waits on this session (avg '
       || to_char(round(&v_lfs_m/nullif(&v_lfs_w,0)/1000, 3), 'FM9990.000') || ' ms) --'
       || chr(10) || 'one synchronous LGWR round-trip per commit. Instance-wide, LGWR did '
       || to_char(&v_lfpw_w, 'FM999,999') || ' ''log file parallel write'' calls in the same window.'
       || chr(10) || 'The same ' || to_char(&lfs_n, 'FM999,999') || ' COMMITs inside one PL/SQL block waited '
       || &v_plsql_w || ' time(s): PL/SQL defers the sync to the end of the call.'
       || chr(10) || 'The fix for high LFS is almost always BATCHING commits (commit FREQUENCY drives'
       || chr(10) || 'the event, not row volume), not faster disk.'
from dual;
set heading on
exit

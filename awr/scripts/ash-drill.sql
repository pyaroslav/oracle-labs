-- ASH DRILL — Active Session History, the "what was active at this moment" view.
-- Runs a ~16s workload, then generates an ASH report for EXACTLY that window. ASH samples active
-- sessions every second, so it shows short-lived activity that an hour-long AWR would average away.
--
-- Why it runs inside FREEPDB1 and uses a tight window:
--  * The workload runs in the PDB. A PDB-level ASH report (dbid = the PDB's CON_DBID) resolves the
--    SQL text; from CDB$ROOT the same SQL shows as "** SQL Text Not Available **".
--  * The window is captured around the workload (begin - 2s .. end + 2s), not "the last 10 minutes",
--    so the CPU/I-O drills that ran just before don't dilute the Top SQL percentages.
--  * The workload must actually SUCCEED: a single CONNECT BY over >~2M rows dies with ORA-30009
--    (Not enough memory for CONNECT BY) on the Free image, so we loop a 1M-row statement instead.
set serveroutput on
alter session set container = FREEPDB1;
variable l_dbid number
variable l_inst number
variable l_btime varchar2(20)
variable l_etime varchar2(20)
begin
  :l_dbid  := to_number(sys_context('userenv', 'con_dbid'));
  select instance_number into :l_inst from v$instance;
  :l_btime := to_char(sysdate - 2/86400, 'YYYY-MM-DD HH24:MI:SS');
end;
/

prompt >> Generating ~16s of activity to sample...
declare
  n number;
begin
  for i in 1 .. 3 loop
    select /*+ ash_demo */ sum(sqrt(level) + ln(level + 1))
    into   n
    from   dual connect by level <= 1000000;
  end loop;
end;
/

-- let the last 1-second samples land in V$ACTIVE_SESSION_HISTORY, then close the window
begin
  dbms_session.sleep(2);
  :l_etime := to_char(sysdate, 'YYYY-MM-DD HH24:MI:SS');
end;
/

-- machine-readable checks for run.sh
set heading off feedback off pagesize 0 linesize 200 trimspool on
prompt >>>SIGNALS
select 'ASH_SAMPLES=' || count(*)
from   v$active_session_history
where  sample_time between to_date(:l_btime, 'YYYY-MM-DD HH24:MI:SS') and to_date(:l_etime, 'YYYY-MM-DD HH24:MI:SS');
select 'ASH_DEMO_SAMPLES=' || count(*)
from   v$active_session_history h
where  sample_time between to_date(:l_btime, 'YYYY-MM-DD HH24:MI:SS') and to_date(:l_etime, 'YYYY-MM-DD HH24:MI:SS')
and    h.sql_id in (select sql_id from v$sql where sql_text like 'SELECT /*+ ash_demo */%');
prompt >>>ENDSIGNALS

prompt
prompt ============================================================
prompt  ASH REPORT (text) for the workload window
prompt ============================================================
set long 90000000 longchunksize 200000
select output
from   table(dbms_workload_repository.ash_report_text(
         :l_dbid, :l_inst,
         to_date(:l_btime, 'YYYY-MM-DD HH24:MI:SS'),
         to_date(:l_etime, 'YYYY-MM-DD HH24:MI:SS')));

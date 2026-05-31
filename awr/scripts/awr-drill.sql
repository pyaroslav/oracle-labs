-- AWR DRILL — generate a real AWR report you can read.
-- Takes a baseline snapshot, runs a known CPU-heavy workload, takes a second snapshot,
-- then prints an AWR report for exactly that interval. Run as SYS (connects to the CDB root;
-- the workload runs inside FREEPDB1). See the post "How to Read an AWR Report Without Drowning".
set serveroutput on
variable bsnap number
variable esnap number
variable l_dbid number
variable l_inst number

prompt >> Baseline AWR snapshot...
begin
  select dbid            into :l_dbid from v$database;
  select instance_number into :l_inst from v$instance;
  :bsnap := dbms_workload_repository.create_snapshot;
end;
/

prompt >> Generating a known workload (CPU-bound, one dominant SQL)...
alter session set container = FREEPDB1;
declare
  n number;
begin
  -- One heavy, CPU-bound statement the optimizer can't shortcut (math over a generated row set).
  -- Run twice so it clearly tops the AWR "SQL ordered by CPU/Elapsed" sections. ~20s total.
  for i in 1 .. 2 loop
    select /*+ awr_demo */ sum(sqrt(level) + ln(level + 1))
    into   n
    from   dual connect by level <= 15000000;
  end loop;
end;
/
alter session set container = cdb$root;

prompt >> Closing AWR snapshot...
begin :esnap := dbms_workload_repository.create_snapshot; end;
/

-- the snapshot pair / dbid we'll report on
set heading on feedback off
select :bsnap as begin_snap, :esnap as end_snap, :l_dbid as dbid, :l_inst as inst from dual;

prompt
prompt ============================================================
prompt  AWR REPORT (text) for the interval above
prompt ============================================================
set heading off feedback off pagesize 0 linesize 200 long 90000000 longchunksize 200000 trimspool on
select output
from   table(dbms_workload_repository.awr_report_text(:l_dbid, :l_inst, :bsnap, :esnap));

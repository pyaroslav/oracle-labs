-- ASH DRILL — Active Session History, the "what was active at this moment" view.
-- Runs a short workload, then generates an ASH report for the recent window. ASH samples active
-- sessions every second, so it shows short-lived activity that an hour-long AWR would average away.
set serveroutput on
variable l_dbid number
variable l_inst number
begin
  select dbid into :l_dbid from v$database;
  select instance_number into :l_inst from v$instance;
end;
/

prompt >> Generating ~15s of activity to sample...
alter session set container = FREEPDB1;
declare
  n number;
begin
  for i in 1 .. 2 loop
    select /*+ ash_demo */ sum(sqrt(level) + ln(level + 1))
    into   n
    from   dual connect by level <= 12000000;
  end loop;
end;
/
alter session set container = cdb$root;

prompt
prompt ============================================================
prompt  ASH REPORT (text) for the last 10 minutes
prompt ============================================================
set heading off feedback off pagesize 0 linesize 200 long 90000000 longchunksize 200000 trimspool on
select output
from   table(dbms_workload_repository.ash_report_text(:l_dbid, :l_inst, sysdate - 10/1440, sysdate));

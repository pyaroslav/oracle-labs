-- The two 2am jobs: their next run, and the run after the November DST change, in Chicago time
set heading off feedback off pages 0 lines 200
alter session set container = FREEPDB1;
select 'NEXT ' || job_name || '=' || to_char(next_run_date at time zone 'America/Chicago', 'HH24:MI')
  from dba_scheduler_jobs where owner = 'TZ_APP' and job_name like 'NIGHTLY%' order by job_name;
set serveroutput on
declare
  n timestamp with time zone;
  after_dst timestamp with time zone := to_timestamp_tz('2026-11-02 12:00 UTC', 'YYYY-MM-DD HH24:MI TZR');
begin
  for j in (select job_name, start_date, repeat_interval from dba_scheduler_jobs
             where owner = 'TZ_APP' and job_name like 'NIGHTLY%' order by job_name) loop
    dbms_scheduler.evaluate_calendar_string(j.repeat_interval, j.start_date, after_dst, n);
    dbms_output.put_line('WINTER ' || j.job_name || '=' || to_char(n at time zone 'America/Chicago', 'HH24:MI'));
  end loop;
end;
/
exit

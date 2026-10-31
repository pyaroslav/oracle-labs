-- Reset the lab: app schema TZ_APP in FREEPDB1, DBTIMEZONE back to UTC, TIME_AT_DBTIMEZONE off.
-- The PDB is reopened by run.sh afterwards so the two time-zone settings take effect.
whenever sqlerror exit failure
alter session set container = FREEPDB1;

begin
  execute immediate 'drop user tz_app cascade';
exception when others then
  if sqlcode != -1918 then raise; end if;
end;
/
create user tz_app identified by "Tz_App_Passw0rd1" quota unlimited on users;
grant create session, create table, create job to tz_app;

-- What the app writes: an order date filled in by the database, the way most schemas do it
create table tz_app.orders (
  id         number primary key,
  placed     varchar2(30),
  order_date date default sysdate not null
);
-- What a scheduler job sees: SYSDATE's offset from UTC, in hours, inside a job slave
create table tz_app.job_probe (run_at varchar2(30), offset_hours number);

-- The on-prem database was created on a Chicago server, so the scheduler default is Chicago
exec dbms_scheduler.set_scheduler_attribute('default_timezone', 'America/Chicago')

-- Two nightly 2am jobs: one with a time-zone region, one with the fixed offset SYSTIMESTAMP gives in summer
begin
  dbms_scheduler.create_job(job_name => 'TZ_APP.NIGHTLY_REGION', job_type => 'PLSQL_BLOCK', job_action => 'null;',
    start_date => to_timestamp_tz('2026-10-01 02:00 America/Chicago', 'YYYY-MM-DD HH24:MI TZR'),
    repeat_interval => 'FREQ=DAILY;BYHOUR=2;BYMINUTE=0;BYSECOND=0', enabled => true);
  dbms_scheduler.create_job(job_name => 'TZ_APP.NIGHTLY_OFFSET', job_type => 'PLSQL_BLOCK', job_action => 'null;',
    start_date => to_timestamp_tz('2026-10-01 02:00 -05:00', 'YYYY-MM-DD HH24:MI TZH:TZM'),
    repeat_interval => 'FREQ=DAILY;BYHOUR=2;BYMINUTE=0;BYSECOND=0', enabled => true);
end;
/

alter database set time_zone = '+00:00';
alter system set time_at_dbtimezone = off scope = spfile;
exit

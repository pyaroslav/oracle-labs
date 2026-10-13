-- How to spot it: log switches per minute over the last hour, and Oracle's own redo-size advice.
-- OPTIMAL_LOGFILE_SIZE (MB) is only computed when FAST_START_MTTR_TARGET is set, so set it briefly here.
set lines 120 pages 100 feedback off
prompt Log switches per minute (last hour):
select to_char(trunc(first_time, 'MI'), 'HH24:MI') as minute, count(*) as switches
  from v$log_history where first_time > sysdate - 1/24
 group by trunc(first_time, 'MI') order by 1;
alter system set fast_start_mttr_target = 60;
exec dbms_session.sleep(5)
prompt Oracle's suggested redo log size for a 60-second recovery target (MB):
select optimal_logfile_size from v$instance_recovery;
alter system set fast_start_mttr_target = 0;
exit

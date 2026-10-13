-- Instance-wide counters, printed as KEY=value lines for run.sh.
set heading off feedback off pages 0 lines 200
select 'CKPT_WAITS=' || nvl(max(total_waits), 0) from v$system_event where event = 'log file switch (checkpoint incomplete)';
select 'CKPT_CS='    || nvl(max(round(time_waited_micro / 10000)), 0) from v$system_event where event = 'log file switch (checkpoint incomplete)';
select 'SWITCHES='   || count(*) from v$log_history;
select 'GROUPS='     || count(*) from v$log;
select 'LOG_MB='     || max(bytes) / 1048576 from v$log;
exit

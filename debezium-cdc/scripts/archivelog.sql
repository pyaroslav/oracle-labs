-- ARCHIVELOG + minimal supplemental logging (CDB level). LogMiner needs both. Safe to rerun.
whenever sqlerror continue
set verify off heading off feedback off pages 0 lines 200 trimspool on
host mkdir -p /opt/oracle/oradata/fra
alter system set db_recovery_file_dest_size = 4G scope=both;
alter system set db_recovery_file_dest = '/opt/oracle/oradata/fra' scope=both;
column log_mode new_value lm noprint
select log_mode from v$database;
-- only bounce the instance when it isn't already in ARCHIVELOG mode
set termout off
spool /tmp/arch_bounce.sql
select case when '&lm' = 'NOARCHIVELOG' then
  'shutdown immediate' || chr(10) || 'startup mount' || chr(10) || 'alter database archivelog;' || chr(10) ||
  'alter database open;' || chr(10) || 'alter pluggable database all open;' else '-- already archivelog' end
from dual;
spool off
set termout on
@/tmp/arch_bounce.sql
alter database add supplemental log data;
select 'LOGMODE=' || log_mode || ' SUPMIN=' || supplemental_log_data_min from v$database;
exit

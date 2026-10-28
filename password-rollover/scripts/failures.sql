-- Failed APP_USER logons since setup, by error code: the audit trail is where the source of a lockout shows up
set heading off feedback off pages 0
alter session set container = FREEPDB1;
select 'FAILED ORA-' || lpad(return_code, 5, '0') || ' x' || count(*) || ' from ' || userhost
from   unified_audit_trail
where  dbusername = 'APP_USER' and action_name = 'LOGON' and return_code <> 0
and    event_timestamp >= (select cast(created as timestamp) from dba_users where username = 'APP_USER')
group  by return_code, userhost
order  by return_code;
exit

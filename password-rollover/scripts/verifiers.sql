-- Which password did each successful APP_USER logon use? LOGON_INFO says VERIFIER=...-OLD or ...-NEW
-- while a rollover is open. Counts since the last password change.
set heading off feedback off pages 0
alter session set container = FREEPDB1;
select 'VERIFIER=' || regexp_substr(authentication_type, 'VERIFIER=([^)]*)', 1, 1, null, 1) || ' LOGONS=' || count(*)
from   unified_audit_trail
where  dbusername = 'APP_USER' and action_name = 'LOGON' and return_code = 0
and    event_timestamp >= (select cast(password_change_date as timestamp) from dba_users where username = 'APP_USER')
group  by regexp_substr(authentication_type, 'VERIFIER=([^)]*)', 1, 1, null, 1)
order  by 1;
exit

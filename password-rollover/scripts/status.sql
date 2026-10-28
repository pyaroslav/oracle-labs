-- Account status and the profile limits that matter here
set heading off feedback off pages 0
alter session set container = FREEPDB1;
select 'STATUS=' || account_status from dba_users where username = 'APP_USER';
select 'ROLLOVER=' || limit from dba_profiles where profile = 'APP_PROF' and resource_name = 'PASSWORD_ROLLOVER_TIME';
exit

-- Reset and build the lab in FREEPDB1: an app account on its own profile, and a logon audit policy for it.
-- APP_PROF: 5 failed logins lock the account for a day; PASSWORD_ROLLOVER_TIME 0 = rollover off.
whenever sqlerror continue
alter session set container = FREEPDB1;
noaudit policy app_logons by app_user;
drop audit policy app_logons;
drop user app_user cascade;
drop profile app_prof cascade;
whenever sqlerror exit failure
create profile app_prof limit
  failed_login_attempts  5
  password_lock_time     1
  password_rollover_time 0;
create user app_user identified by "Spring_Passw0rd1" profile app_prof;
grant create session to app_user;
-- every APP_USER logon, success and failure, lands in UNIFIED_AUDIT_TRAIL
create audit policy app_logons actions logon;
audit policy app_logons by app_user;
exit

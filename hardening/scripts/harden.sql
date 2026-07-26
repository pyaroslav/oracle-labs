-- harden.sql — apply the six controls from the checklist. Run as SYSDBA. Idempotent.
-- Each block corresponds to a check in audit.sql; after this runs, every check must read 0.
set echo off feedback off verify off
whenever sqlerror continue
alter session set container = FREEPDB1;

-- 1. Close the default-password account (lock + expire = it can no longer authenticate).
alter user demo account lock password expire;

-- 2a. Take the network packages back from PUBLIC. Loop + ignore "not granted" so it's safe whatever
--     the delivered defaults were — revoking them all is exactly the hardening action.
begin
  for p in (select column_value pkg from table(sys.odcivarchar2list(
              'UTL_HTTP','UTL_TCP','UTL_SMTP','UTL_INADDR','UTL_FILE'))) loop
    begin execute immediate 'revoke execute on '||p.pkg||' from public';
    exception when others then null; end;
  end loop;
end;
/

-- 2b. Remove the ANY-privilege from the app account.
begin execute immediate 'revoke select any table from appuser'; exception when others then null; end;
/

-- 2c. Remove DBA from the app account.
begin execute immediate 'revoke dba from appuser'; exception when others then null; end;
/

-- 5. Give the DEFAULT profile a real failed-login lockout and password lifetime.
--    (A password_verify_function belongs here too — see the README/blog — but it depends on the
--     verify-function catalog being present, so it's left as a documented manual step.)
alter profile default limit
  failed_login_attempts 10
  password_life_time 180;

-- 6. Re-enable the unified-auditing baseline.
audit policy ora_secureconfig;
audit policy ora_logon_failures;

exit

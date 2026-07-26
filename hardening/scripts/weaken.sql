-- weaken.sql — put FREEPDB1 into a realistic, deliberately-insecure state so the audit has real
-- findings. Every weakness here maps to a section of the blog checklist. Run as SYSDBA.
-- Idempotent: safe to re-run.
set echo off feedback off verify off
whenever sqlerror continue
alter session set container = FREEPDB1;

-- Open the DEFAULT profile FIRST (no verify function, no lifetime/lockout) so a password = username
-- account is accepted below. This is checklist item 5, wide open.
alter profile default limit
  failed_login_attempts unlimited
  password_life_time unlimited
  password_verify_function null;

-- Clean slate for the demo accounts.
begin execute immediate 'drop user demo cascade';    exception when others then null; end;
/
begin execute immediate 'drop user appuser cascade'; exception when others then null; end;
/

-- 1. A default-password account: password equals the username, and it can log in.
create user demo identified by demo;
grant create session to demo;

-- An application account we are about to over-privilege.
create user appuser identified by "Str0ng_App#2026_x";
grant create session to appuser;

-- 2a. A network package granted to PUBLIC (an exfiltration primitive for any compromised account).
grant execute on utl_http to public;

-- 2b. An ANY-privilege handed to the app account for convenience.
grant select any table to appuser;

-- 2c. DBA on the app account — a super-role where a tailored one belongs.
grant dba to appuser;

-- 6. Turn OFF the unified-auditing baseline (these are on by default in a modern DB — this simulates
-- someone having disabled them).
begin execute immediate 'noaudit policy ora_secureconfig';   exception when others then null; end;
/
begin execute immediate 'noaudit policy ora_logon_failures'; exception when others then null; end;
/

exit

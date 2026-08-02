-- setup.sql — a sensitive table, a low-priv reader, the baseline policies, and one custom policy.
-- Run as SYSDBA. Idempotent (safe to re-run).
set echo off feedback off verify off
whenever sqlerror continue
alter session set container = FREEPDB1;

-- clean slate ---------------------------------------------------------------------------------
begin execute immediate 'noaudit policy aud_salary_access';       exception when others then null; end;
/
begin execute immediate 'drop audit policy aud_salary_access';    exception when others then null; end;
/
begin execute immediate 'drop user auditee cascade';              exception when others then null; end;
/
begin execute immediate 'drop user aud_probe cascade';            exception when others then null; end;
/
begin execute immediate 'drop user hr cascade';                   exception when others then null; end;
/

-- a schema with a sensitive table -------------------------------------------------------------
create user hr identified by "Lab_Passw0rd1" quota unlimited on users;
grant create session, create table to hr;
create table hr.employee_salary (id number primary key, name varchar2(40), salary number);
insert into hr.employee_salary values (1, 'Alice', 120000);
insert into hr.employee_salary values (2, 'Bob',    95000);
commit;

-- a low-privilege user who will read the sensitive table (our "auditee") ----------------------
create user auditee identified by "Lab_Passw0rd1";
grant create session to auditee;
grant select on hr.employee_salary to auditee;

-- keep the baseline Oracle pre-enables (idempotent: 'already enabled' is fine) -----------------
begin execute immediate 'audit policy ORA_SECURECONFIG';   exception when others then null; end;
/
begin execute immediate 'audit policy ORA_LOGON_FAILURES'; exception when others then null; end;
/

-- our own NARROW policy: audit reads of the one sensitive table -------------------------------
create audit policy aud_salary_access actions select, update, delete on hr.employee_salary;
audit policy aud_salary_access;

exit

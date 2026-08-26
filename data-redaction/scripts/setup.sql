-- setup.sql — build one table of fake-but-sensitive rows and protect it with DBMS_REDACT, then create
-- two readers: CLERK (ordinary, subject to the policy) and AUDITOR (holds EXEMPT REDACTION POLICY).
-- Run as SYSDBA. Idempotent (safe to re-run).
--
-- Redaction is a READ-TIME transform: it changes what a query RETURNS, never the stored data. So the
-- card prefix '4111-2222-3333' is written to disk in the clear and stays there — the `disk` drill greps
-- for it. That is the whole point of the TDE contrast: encryption removes data from the datafile;
-- redaction leaves it on disk and masks it on the way out.
set echo off feedback off verify off
whenever sqlerror continue
alter session set container = FREEPDB1;

-- clean slate ---------------------------------------------------------------------------------------
-- dropping REDOWN cascade also drops the table and its redaction policy.
begin execute immediate 'drop user redown cascade';  exception when others then null; end;
/
begin execute immediate 'drop user clerk cascade';   exception when others then null; end;
/
begin execute immediate 'drop user auditor cascade'; exception when others then null; end;
/
begin execute immediate 'drop tablespace red_data including contents and datafiles'; exception when others then null; end;
/

-- an ordinary (unencrypted) tablespace at a known datafile path, so `disk` can grep the raw file -----
create tablespace red_data
  datafile '/opt/oracle/oradata/FREE/FREEPDB1/red_data.dbf' size 50m;

create user redown  identified by "Lab_Passw0rd1" quota unlimited on red_data;
grant create session, create table to redown;

create user clerk   identified by "Lab_Passw0rd1";
grant create session to clerk;

create user auditor identified by "Lab_Passw0rd1";
grant create session to auditor;

-- the sensitive table: fake card numbers, SSNs, emails, salaries -------------------------------------
create table redown.customers (
  id      number primary key,
  name    varchar2(40),
  ssn     varchar2(11),
  card    varchar2(19),
  email   varchar2(60),
  salary  number
) tablespace red_data;

-- deterministic rows so the drills can assert exact values for id = 1:
--   card '4111-2222-3333-0001'  ssn '123-45-0001'  email 'user0001@example.com'  salary 50001
insert into redown.customers
  select rownum,
         'Customer_'||lpad(rownum,4,'0'),
         '123-45-'||lpad(mod(rownum,10000),4,'0'),
         '4111-2222-3333-'||lpad(mod(rownum,10000),4,'0'),
         'user'||lpad(rownum,4,'0')||'@example.com',
         50000 + rownum
  from dual connect by level <= 2000;
commit;

grant select on redown.customers to clerk;
grant select on redown.customers to auditor;

-- === the redaction policy: one policy, four columns, four function types ============================
-- expression '1=1' => every user SUBJECT to redaction is redacted. AUDITOR is not subject because it
-- holds EXEMPT REDACTION POLICY (granted below), so it bypasses the whole policy.
begin
  -- CARD: PARTIAL, using the built-in 16-digit credit-card format -> shows only the last 4 digits.
  dbms_redact.add_policy(
    object_schema       => 'REDOWN',
    object_name         => 'CUSTOMERS',
    policy_name         => 'RED_CUSTOMERS',
    column_name         => 'CARD',
    function_type       => dbms_redact.partial,
    function_parameters => dbms_redact.redact_ccn16_f12,
    expression          => '1=1');

  -- SSN: PARTIAL, built-in US SSN format -> shows only the last 4 (XXX-XX-0001).
  dbms_redact.alter_policy(
    object_schema       => 'REDOWN',
    object_name         => 'CUSTOMERS',
    policy_name         => 'RED_CUSTOMERS',
    action              => dbms_redact.add_column,
    column_name         => 'SSN',
    function_type       => dbms_redact.partial,
    function_parameters => dbms_redact.redact_us_ssn_f5);

  -- EMAIL: REGEXP -> mask the name part, keep the domain (xxxx@example.com).
  dbms_redact.alter_policy(
    object_schema         => 'REDOWN',
    object_name           => 'CUSTOMERS',
    policy_name           => 'RED_CUSTOMERS',
    action                => dbms_redact.add_column,
    column_name           => 'EMAIL',
    function_type         => dbms_redact.regexp,
    regexp_pattern        => dbms_redact.re_pattern_email_address,
    regexp_replace_string => dbms_redact.re_redact_email_name,
    regexp_position       => dbms_redact.re_beginning,
    regexp_occurrence     => dbms_redact.re_all);

  -- SALARY: FULL -> a NUMBER column redacts to 0.
  dbms_redact.alter_policy(
    object_schema => 'REDOWN',
    object_name   => 'CUSTOMERS',
    policy_name   => 'RED_CUSTOMERS',
    action        => dbms_redact.add_column,
    column_name   => 'SALARY',
    function_type => dbms_redact.full);
end;
/

-- AUDITOR sees the real values: the exempt privilege makes it bypass every redaction policy.
grant exempt redaction policy to auditor;

-- flush blocks to disk so `disk` reads real bytes from the datafile, not the buffer cache
alter system checkpoint;
alter system flush buffer_cache;
exit

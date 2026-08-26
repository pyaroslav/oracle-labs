-- read.sql — read customer id = 1 back from the table and report what THIS user sees. Run once as CLERK
-- (subject to the policy -> masked) and once as AUDITOR (exempt -> real values). Connects straight to the
-- PDB service as the user, so no container switch. Emits one KEY=VALUE line per field for run.sh.
--
-- IMPORTANT: a redacted column used inside a SQL EXPRESSION returns NULL -- that is DBMS_REDACT's anti-bypass
-- behavior (you can't wrap the column in a function to leak the real value). So we must NOT do 'CARD='||card.
-- Instead we select the BARE column (which redacts to a masked string), capture it with SQL*Plus NEW_VALUE,
-- and glue the label on CLIENT-side with `prompt`. WHOAMI and the INFER count aren't redacted columns, so
-- those stay as ordinary selects.
--
-- INFER is the gotcha: the WHERE clause filters on the TRUE stored card number. Redaction masks the OUTPUT
-- column, not the predicate, so even a user who only ever sees '****-****-****-0001' can confirm a full card
-- number by guessing it in a WHERE clause. Redaction is a display control, not access control.
set heading off pagesize 0 feedback off verify off termout off

column cv new_value cardv  noprint
select card   cv from redown.customers where id = 1;
column sv new_value ssnv   noprint
select ssn    sv from redown.customers where id = 1;
column ev new_value emailv noprint
select email  ev from redown.customers where id = 1;
column lv new_value salv   noprint
select salary lv from redown.customers where id = 1;

set termout on
prompt >>>SIGNALS
select 'WHOAMI='||user from dual;
prompt CARD=&cardv
prompt SSN=&ssnv
prompt EMAIL=&emailv
prompt SALARY=&salv
select 'INFER='||count(*) from redown.customers where card = '4111-2222-3333-0001';
prompt >>>ENDSIGNALS
exit

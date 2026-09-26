-- loss.sql -- model "the migration completed successfully" into a NARROWER target character set. CONVERT(name,
-- <target>, 'AL32UTF8') is exactly what the target database's character-set conversion does on import: it maps
-- each character from the AL32UTF8 source into the target set. A character the target cannot represent is
-- either transliterated (e.g. Jose with e-acute -> plain Jose, the accent silently dropped) or, when there is
-- no mapping at all, replaced with '?'. A round-trip that does not return the original value is data loss.
-- The row count is unchanged and no error is raised -- which is why this passes every naive migration check.
-- Run as SYSDBA in the PDB.
set echo off feedback off verify off heading off pagesize 0 linesize 200 trimspool on define off
alter session set container = FREEPDB1;
prompt >>>SIGNALS
select 'ROWS_AFTER='||count(*) from csmig.customers;
select 'US7_LOST='||count(*)  from csmig.customers
  where convert(convert(name,'US7ASCII','AL32UTF8'),'AL32UTF8','US7ASCII') <> name;
select 'WE8_LOST='||count(*)  from csmig.customers
  where convert(convert(name,'WE8MSWIN1252','AL32UTF8'),'AL32UTF8','WE8MSWIN1252') <> name;
select 'HAS_QMARK='||count(*) from csmig.customers
  where instr(convert(name,'US7ASCII','AL32UTF8'),'?') > 0;
prompt >>>ENDSIGNALS
prompt >>>EXAMPLES
select rpad(name,12)||' ->  '||convert(name,'US7ASCII','AL32UTF8')||'   (US7ASCII target)'
  from csmig.customers
  where convert(convert(name,'US7ASCII','AL32UTF8'),'AL32UTF8','US7ASCII') <> name
  order by id;
prompt >>>ENDEXAMPLES
exit

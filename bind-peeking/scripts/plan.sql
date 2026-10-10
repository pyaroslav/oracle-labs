-- Final (resolved) plan + ACS flags of one child cursor (&1 = sql_id, &2 = child number), as SYSDBA.
-- An adaptive plan keeps both NESTED LOOPS and HASH JOIN rows in V$SQL_PLAN; DISPLAY_CURSOR shows only what ran.
set feedback off heading off verify off pagesize 0 linesize 200
alter session set container = FREEPDB1;
select plan_table_output from table(dbms_xplan.display_cursor('&1', &2, 'BASIC'));
select 'BSENS='||is_bind_sensitive||chr(10)||'BAWARE='||is_bind_aware from v$sql where sql_id = '&1' and child_number = &2;
exit

-- delete.sql — run as SYSDBA. Deletes 99% of the rows (keeps every 100th id) and commits. The rows are gone;
-- the blocks they lived in stay below the high-water mark.
set echo off feedback off verify off heading off pagesize 0
alter session set container = FREEPDB1;
whenever sqlerror exit failure
delete from hwm.t where mod(id, 100) <> 0;
commit;
exit

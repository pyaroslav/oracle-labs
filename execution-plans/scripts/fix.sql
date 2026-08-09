-- fix.sql — give the optimizer the one thing it was missing: a histogram on the skewed column.
-- Run as SYSDBA. no_invalidate=>false so the cached full-scan cursor re-parses immediately.
set echo off feedback off verify off
alter session set container = FREEPDB1;

begin
  dbms_stats.gather_table_stats(
    ownname       => 'SHOP',
    tabname       => 'ORDERS',
    method_opt    => 'FOR COLUMNS SIZE 254 STATUS',   -- frequency histogram on status
    cascade       => true,
    no_invalidate => false);
end;
/
exit

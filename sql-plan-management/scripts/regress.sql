-- regress.sql — simulate the everyday event that breaks a good plan: a re-gather drops the histogram.
-- Re-gathering STATUS with SIZE 1 removes the frequency histogram, so the optimizer falls back to the
-- 1/NDV assumption and estimates ~a third of the table for `status = 'OPEN'` — making a FULL SCAN look
-- cheaper than the index. The index still exists, so the captured baseline plan stays reproducible.
-- Run as SYSDBA. no_invalidate=>false so the cursor is re-parsed immediately.
set echo off feedback off verify off
alter session set container = FREEPDB1;

begin
  dbms_stats.gather_table_stats('SHOP', 'ORDERS',
    method_opt    => 'FOR COLUMNS STATUS SIZE 1',
    no_invalidate => false);
end;
/
exit

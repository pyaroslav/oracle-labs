-- fix.sql — create an EXTENDED STATISTIC on the (make, model) column group and re-gather, so the
-- optimizer learns the two columns are correlated. Run as SYSDBA. no_invalidate=>false to re-parse now.
set echo off feedback off verify off
alter session set container = FREEPDB1;

declare
  ext varchar2(30);
begin
  -- create the column group (ignore if it already exists), then gather so its NDV is populated
  begin
    ext := dbms_stats.create_extended_stats(ownname => 'SALES', tabname => 'CARS',
                                             extension => '(make, model)');
  exception when others then null;
  end;
  dbms_stats.gather_table_stats(
    ownname       => 'SALES',
    tabname       => 'CARS',
    method_opt    => 'FOR ALL COLUMNS SIZE 1',
    cascade       => true,
    no_invalidate => false);
end;
/
exit

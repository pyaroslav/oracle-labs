-- measure.sql — run as SYSDBA. Full-scans HWM.T (FULL hint, so it reads the table, not the PK index) and reports
-- the rows found and the consistent gets that scan cost (V$MYSTAT delta, second run so cleanout/caching don't
-- skew it), plus the segment's blocks below the HWM (fresh stats) and its allocated blocks.
set echo off feedback off verify off heading off pagesize 0 linesize 200 trimspool on
alter session set container = FREEPDB1;
set serveroutput on   -- after the container switch, which resets the dbms_output buffer
exec dbms_stats.gather_table_stats('HWM', 'T')
declare
  n  number;
  g0 number;
  g1 number;
  function gets return number is
    v number;
  begin
    select m.value into v from v$mystat m join v$statname s on s.statistic# = m.statistic#
     where s.name = 'consistent gets';
    return v;
  end;
begin
  select /*+ full(t) */ count(pad) into n from hwm.t t;   -- warm-up: delayed block cleanout, caching
  g0 := gets;
  select /*+ full(t) */ count(pad) into n from hwm.t t;
  g1 := gets;
  dbms_output.put_line('ROWS=' || n);
  dbms_output.put_line('GETS=' || (g1 - g0));
end;
/
prompt >>>SIGNALS
select 'HWM_BLOCKS='||blocks from dba_tables where owner = 'HWM' and table_name = 'T';
select 'SEG_BLOCKS='||blocks from dba_segments where owner = 'HWM' and segment_name = 'T';
prompt >>>ENDSIGNALS
exit

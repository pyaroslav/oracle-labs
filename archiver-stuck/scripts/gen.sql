-- gen.sql — generate a chunk of redo inside the PDB (about 30 MB, more than one 20 MB online redo log), so the
-- reproduce loop's log switch archives a full redo log into the tiny FRA. Run as SYSDBA (switches into the PDB).
set echo off feedback off verify off heading off pagesize 0 linesize 200 trimspool on
alter session set container = FREEPDB1;
insert into arc.t select level, lpad('x', 200, 'x') from dual connect by level <= 150000;
commit;
exit

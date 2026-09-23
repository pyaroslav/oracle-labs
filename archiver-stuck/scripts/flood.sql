-- flood.sql — one "application" session that generates a burst of redo (~60 MB) inside the PDB. With the
-- archiver already stuck (its destination in ERROR), this fills the online redo logs and then BLOCKS, unable to
-- switch into an unarchived log -- exactly what a real hung session looks like. run.sh runs this detached so it
-- can hold the instance in the locked state while a normal user tries (and fails, with ORA-00257) to connect.
-- Bounded to a single insert so that once the fix unblocks it, it finishes quickly without re-filling the FRA.
set echo off feedback off verify off heading off pagesize 0 linesize 200 trimspool on
alter session set container = FREEPDB1;
insert into arc.t select level, lpad('F', 200, 'F') from dual connect by level <= 300000;
commit;
exit

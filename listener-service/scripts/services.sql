-- What the database thinks it is offering (the listener may disagree)
set heading off feedback off pages 0 lines 200
alter session set container = FREEPDB1;
select 'PDB_OPEN=' || replace(open_mode, ' ', '_') from v$pdbs where name = 'FREEPDB1';
select 'ACTIVE=' || name from v$active_services order by name;
exit

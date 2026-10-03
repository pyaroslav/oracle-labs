-- fix.sql — run as SYSDBA. SHRINK SPACE compacts the remaining rows into the start of the segment, lowers the
-- high-water mark and releases the space. Online (brief lock only at the end); indexes stay usable. Needs row
-- movement because rows get new ROWIDs.
set echo off feedback off verify off heading off pagesize 0
alter session set container = FREEPDB1;
whenever sqlerror exit failure
alter table hwm.t enable row movement;
alter table hwm.t shrink space;
exit

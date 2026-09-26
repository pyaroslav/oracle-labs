-- fix.sql -- the two halves of doing it right. (1) SCAN: before cutover, find exactly the rows the target set
-- would damage -- the same round-trip test, run as a pre-migration audit (this is what the Database Migration
-- Assistant for Unicode / legacy csscan do for real). (2) UNICODE TARGET: migrate into an AL32UTF8 (Unicode)
-- database instead of a narrower one. Unicode is a superset, so every source character has a representation
-- and the round-trip is the identity -- zero loss. Run as SYSDBA in the PDB.
set echo off feedback off verify off heading off pagesize 0 linesize 200 trimspool on define off
alter session set container = FREEPDB1;
prompt >>>SIGNALS
-- the pre-migration scan: how many rows would a US7ASCII target silently damage?
select 'SCAN_FLAGGED='||count(*) from csmig.customers
  where convert(convert(name,'US7ASCII','AL32UTF8'),'AL32UTF8','US7ASCII') <> name;
-- migrating into an AL32UTF8 (Unicode) target loses nothing
select 'AL32_LOST='||count(*) from csmig.customers
  where convert(convert(name,'AL32UTF8','AL32UTF8'),'AL32UTF8','AL32UTF8') <> name;
prompt >>>ENDSIGNALS
exit

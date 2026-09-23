-- setup.sql — build the archiver-stuck lab. Put the database in ARCHIVELOG mode, point archiving at a dedicated
-- Fast Recovery Area, and create a schema that can generate redo. The FRA is later shrunk (by run.sh, via
-- shrink.sql) to a tiny fixed size so a little redo and a few log switches fill it and the archiver (ARCn) can
-- no longer write a new archived redo log -- the "stuck archiver" condition behind ORA-00257. Run as SYSDBA at
-- the CDB root: redo logs and archiving are CDB-wide. NOTE: SQL*Plus treats a trailing '-' as line continuation,
-- so marker lines never end in a hyphen.
set echo off feedback off verify off heading off pagesize 0 linesize 200 trimspool on

-- Point archiving at the dedicated FRA. Start GENEROUS so this is safe to re-run whatever a prior run left in
-- the FRA; run.sh then clears old archived logs and shrink.sql squeezes the FRA down to the tiny lab size.
alter system set db_recovery_file_dest_size = 2g scope=both;
alter system set db_recovery_file_dest = '/opt/oracle/fra' scope=both;
alter system set log_archive_dest_1 = 'LOCATION=USE_DB_RECOVERY_FILE_DEST' scope=both;

-- Enable ARCHIVELOG mode (needs a mount; the guarded block makes it harmless if already enabled).
shutdown immediate
startup mount
begin execute immediate 'alter database archivelog'; exception when others then null; end;
/
alter database open;
alter pluggable database all open;

-- A schema that can generate redo, plus a result table for the drill signals. Built inside the PDB.
alter session set container = FREEPDB1;
begin execute immediate 'drop user arc cascade'; exception when others then null; end;
/
create user arc identified by "Lab_Passw0rd1" quota unlimited on users;
grant create session, create table to arc;
create table arc.t (id number, pad varchar2(200));
create table arc.result (k varchar2(30), v varchar2(200));
exit

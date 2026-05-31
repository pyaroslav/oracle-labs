-- I/O DRILL — produce an I/O signature in AWR.
-- Flushes the buffer cache and full-scans a table bigger than the cache, so every scan reads from
-- disk as buffered multiblock reads (db file scattered read). Flush + scan are TOP-LEVEL statements
-- (a flush issued inside a PL/SQL loop doesn't evict reliably). On fast local NVMe the *wait time*
-- is small, but the physical-read volume and the Reads/Segments sections are real.
variable bsnap number
variable esnap number
variable l_dbid number
variable l_inst number

prompt >> Baseline snapshot...
begin
  select dbid into :l_dbid from v$database;
  select instance_number into :l_inst from v$instance;
  :bsnap := dbms_workload_repository.create_snapshot;
end;
/

prompt >> I/O workload: flush cache + full-scan a ~1.4GB table (x3, from disk)...
alter session set container = FREEPDB1;
alter session set "_serial_direct_read" = never;   -- force buffered reads -> db file scattered read

alter system flush buffer_cache;
select /*+ io_demo full(b) */ count(*) from labuser.bigtab b where filler like '%zzz%';
alter system flush buffer_cache;
select /*+ io_demo full(b) */ count(*) from labuser.bigtab b where filler like '%zzz%';
alter system flush buffer_cache;
select /*+ io_demo full(b) */ count(*) from labuser.bigtab b where filler like '%zzz%';

alter session set container = cdb$root;

prompt >> Closing snapshot...
begin :esnap := dbms_workload_repository.create_snapshot; end;
/

set heading off feedback off pagesize 0 linesize 200 long 90000000 longchunksize 200000 trimspool on
select output
from   table(dbms_workload_repository.awr_report_text(:l_dbid, :l_inst, :bsnap, :esnap));

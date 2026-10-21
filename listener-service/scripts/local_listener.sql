-- The fix: tell the database where ALL its listeners are. LREG registers with the new address immediately.
whenever sqlerror exit failure
alter system set local_listener =
  '(ADDRESS_LIST=(ADDRESS=(PROTOCOL=TCP)(HOST=localhost)(PORT=1521))(ADDRESS=(PROTOCOL=TCP)(HOST=localhost)(PORT=1522)))'
  scope = memory;
set heading off feedback off pages 0 lines 300
select 'LOCAL_LISTENER=' || value from v$parameter where name = 'local_listener';
exit

-- The fix: start the service and save the PDB's state, so it comes back with the PDB
whenever sqlerror exit failure
alter session set container = FREEPDB1;
exec dbms_service.start_service('orders_app')
alter pluggable database FREEPDB1 save state;
exit

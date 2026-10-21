-- Reset to a known state (safe to rerun): no ORDERS_APP service, LOCAL_LISTENER at its default, then create
-- ORDERS_APP the way many shops do it — DBMS_SERVICE, started by hand, never saved.
whenever sqlerror exit failure
alter system set local_listener = '' scope = memory;
alter session set container = FREEPDB1;
declare
  n number;
begin
  select count(*) into n from dba_services where name = 'orders_app';
  if n > 0 then
    begin dbms_service.stop_service('orders_app'); exception when others then null; end;
    dbms_service.delete_service('orders_app');
  end if;
end;
/
-- record the PDB's state without the app service, so a rerun starts clean
alter pluggable database FREEPDB1 save state;
exec dbms_service.create_service(service_name => 'orders_app', network_name => 'orders_app')
exec dbms_service.start_service('orders_app')
alter system register;
exit

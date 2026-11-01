-- Open-cursors lab setup (run as SYSDBA). Resets the lab: safe to rerun.
whenever sqlerror exit failure
alter session set container = FREEPDB1;
-- this image runs with 300 (the parameter's own default is 50); a previous "raise" run may have left 400
whenever sqlerror continue
alter system set open_cursors = 300;
-- end any APP session left by a previous run (a background session would block DROP USER), wait until gone
declare n number;
begin
  for s in (select sid, serial# from v$session where username = 'APP') loop
    begin execute immediate 'alter system kill session ''' || s.sid || ',' || s.serial# || ''' immediate';
    exception when others then null; end;
  end loop;
  for i in 1 .. 60 loop
    select count(*) into n from v$session where username = 'APP';
    exit when n = 0;
    dbms_session.sleep(0.5);
  end loop;
  select count(*) into n from dba_users where username = 'APP';
  if n > 0 then execute immediate 'drop user app cascade'; end if;
end;
/
whenever sqlerror exit failure
create user app identified by "App_Passw0rd1" quota unlimited on users;
grant create session, create table, create procedure to app;

create table app.orders as
  select level id, mod(level, 100) customer_id, sysdate - level/24 created
  from dual connect by level <= 1000;

-- The app's data-access layer: returns a result set (a ref cursor) to the caller.
-- Whoever calls it owns the cursor and must close it.
create or replace procedure app.get_orders(p_cust in number, p_rc out sys_refcursor) as
begin
  open p_rc for select id, created from app.orders where customer_id = p_cust;
end;
/
-- A second, unrelated call: the one that happens to need the 301st cursor
create or replace procedure app.get_customer(p_cust in number, p_rc out sys_refcursor) as
begin
  open p_rc for select count(*) n from app.orders where customer_id = p_cust and created > sysdate - 7;
end;
/
exit

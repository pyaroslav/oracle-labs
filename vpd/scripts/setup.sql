-- setup.sql — build an ORDERS table split across two regions and protect it with a Virtual Private
-- Database (row-level security) policy, then create three readers: REP_EAST and REP_WEST (each confined to
-- their own region) and MGR (holds EXEMPT ACCESS POLICY -> sees every row). Run as SYSDBA. Idempotent.
--
-- VPD (DBMS_RLS) transparently APPENDS a WHERE predicate to every query on the table, per session. Unlike a
-- view, there is nothing to route around: the predicate is enforced on the base table for every statement --
-- counts, aggregates, and a targeted lookup by id alike. This is the ROW-level counterpart to Data
-- Redaction's COLUMN masking: redaction hides a value but keeps the row; VPD removes the row entirely.
set echo off feedback off verify off
whenever sqlerror continue
alter session set container = FREEPDB1;

-- clean slate ---------------------------------------------------------------------------------------
begin execute immediate 'drop user vpdown cascade';   exception when others then null; end;
/
begin execute immediate 'drop user rep_east cascade'; exception when others then null; end;
/
begin execute immediate 'drop user rep_west cascade'; exception when others then null; end;
/
begin execute immediate 'drop user mgr cascade';      exception when others then null; end;
/

-- schema owner + three readers ----------------------------------------------------------------------
create user vpdown identified by "Lab_Passw0rd1" default tablespace users quota unlimited on users;
grant create session, create table, create procedure to vpdown;

create user rep_east identified by "Lab_Passw0rd1";
grant create session to rep_east;
create user rep_west identified by "Lab_Passw0rd1";
grant create session to rep_west;
create user mgr identified by "Lab_Passw0rd1";
grant create session to mgr;

-- the table: 3,000 orders, deterministically split 1,800 EAST / 1,200 WEST, flat amount 100 ----------
create table vpdown.orders (
  id       number primary key,
  region   varchar2(4),
  customer varchar2(40),
  amount   number
);

insert into vpdown.orders
  select rownum,
         case when mod(rownum,5) in (0,1,2) then 'EAST' else 'WEST' end,
         'Cust_'||lpad(rownum,4,'0'),
         100
  from dual connect by level <= 3000;
commit;

grant select on vpdown.orders to rep_east, rep_west, mgr;

-- === the VPD policy: a function returns the per-session predicate; DBMS_RLS applies it to SELECT =======
-- The RLS engine calls this function for each querying session and appends whatever predicate it returns.
-- It keys off the UNSPOOFABLE session user (USERENV.SESSION_USER): each rep gets their region, and anyone
-- else is denied every row (1=2). MGR never reaches this function because it holds EXEMPT ACCESS POLICY
-- (granted below) and bypasses the policy entirely.
create or replace function vpdown.orders_rls(p_schema in varchar2, p_object in varchar2)
  return varchar2 is
begin
  return case sys_context('userenv','session_user')
           when 'REP_EAST' then 'region = ''EAST'''
           when 'REP_WEST' then 'region = ''WEST'''
           else '1=2'
         end;
end;
/

begin
  begin
    dbms_rls.drop_policy(object_schema => 'VPDOWN', object_name => 'ORDERS',
                         policy_name => 'ORDERS_REGION_POLICY');
  exception when others then null; end;
  dbms_rls.add_policy(
    object_schema   => 'VPDOWN',
    object_name     => 'ORDERS',
    policy_name     => 'ORDERS_REGION_POLICY',
    function_schema => 'VPDOWN',
    policy_function => 'ORDERS_RLS',
    statement_types => 'SELECT');
end;
/

-- MGR bypasses every VPD policy — the row-level analog of EXEMPT REDACTION POLICY.
grant exempt access policy to mgr;
exit

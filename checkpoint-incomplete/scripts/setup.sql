-- Build the workload: CK.T with 100,000 rows of ~1 KB in FREEPDB1. Re-runnable.
whenever sqlerror exit failure
alter session set container=FREEPDB1;
begin execute immediate 'drop user ck cascade'; exception when others then if sqlcode != -1918 then raise; end if; end;
/
create user ck identified by "Ck_Passw0rd1" quota unlimited on users;
create table ck.t (id number primary key, pad varchar2(1000)) tablespace users;
insert /*+ append */ into ck.t select level, rpad('a', 1000, 'a') from dual connect by level <= 100000;
commit;
exit

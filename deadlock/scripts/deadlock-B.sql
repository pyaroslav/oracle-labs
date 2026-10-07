-- SESSION B of the deadlock. Launched ~2s after A. Locks id=2, then reaches for id=1
-- (A holds it) -> blocks -> the cycle closes -> Oracle raises ORA-00060.
-- Keep whenever sqlerror at its DEFAULT (continue): the victim must run PAST the error
-- so the ORA-00060 prints and the session still reaches commit.
set echo on feedback on time on define off
alter session set container = FREEPDB1;
select sys_context('USERENV','SID') as sid_b from dual;
update labuser.dl_acct set balance = balance - 1 where id = 2;
prompt SESSION B locked id=2, now reaching for id=1 which A holds
set serveroutput on
begin
  update labuser.dl_acct set balance = balance - 1 where id = 1;
  dbms_output.put_line('SESSION B acquired id=1, B was not the deadlock victim');
exception when others then
  -- the victim prints the real error, and only THIS statement is rolled back (id=... it already holds stays locked)
  dbms_output.put_line('SESSION B was the deadlock victim -> ' || sqlerrm);
  dbms_output.put_line('SESSION B keeps its earlier lock; only the failed UPDATE was rolled back');
end;
/
commit;
exit

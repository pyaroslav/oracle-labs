-- SESSION B of the deadlock. Launched ~2s AFTER A. Locks id=2, then reaches for
-- id=1 (A holds it) -> blocks -> the cycle closes -> Oracle raises ORA-00060.
-- Keep whenever sqlerror at its DEFAULT (continue): the victim must run PAST the
-- error so the ORA-00060 prints and the session still reaches commit.
set echo on feedback on time on
alter session set container = FREEPDB1;
select sys_context('USERENV','SID') as sid_b from dual;

update labuser.dl_acct set balance = balance - 1 where id = 2;   -- locks id=2 (A still holding id=1)
prompt SESSION B: locked id=2; now reaching for id=1 (A holds it) -> blocks, then deadlock...
update labuser.dl_acct set balance = balance - 1 where id = 1;   -- ORA-00060 raised here if B is the victim
prompt SESSION B: acquired id=1 (B was not the deadlock victim).
commit;
exit

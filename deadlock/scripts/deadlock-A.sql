-- SESSION A of the deadlock. Locks id=1, holds it (sleep), THEN reaches for id=2.
-- A COMMIT would release the row lock, so A does NOT commit until after it has
-- (tried to) grab id=2 — the sleep is what holds id=1 locked while B forms the cycle.
set echo on feedback on time on
alter session set container = FREEPDB1;
select sys_context('USERENV','SID') as sid_a from dual;

update labuser.dl_acct set balance = balance - 1 where id = 1;   -- locks id=1
prompt SESSION A: locked id=1; holding it so B can lock id=2 and form the cycle...
exec dbms_session.sleep(6);                                      -- HOLD the lock (no commit!)
update labuser.dl_acct set balance = balance - 1 where id = 2;   -- now wants id=2 (B holds it)
prompt SESSION A: acquired id=2 (A was not the deadlock victim).
commit;
exit

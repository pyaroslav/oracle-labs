-- SESSION A of the deadlock. Locks id=1, holds it (sleep), then reaches for id=2.
-- A COMMIT would release the row lock, so A does not commit until after it has tried
-- to grab id=2. The sleep is what holds id=1 locked while B forms the other half.
-- (Prompts avoid ':' and ';' so SQL*Plus never mistakes them for bind vars / terminators.)
set echo on feedback on time on define off
alter session set container = FREEPDB1;
select sys_context('USERENV','SID') as sid_a from dual;
update labuser.dl_acct set balance = balance - 1 where id = 1;
prompt SESSION A locked id=1, holding it so B can lock id=2 and form the cycle
begin dbms_session.sleep(6); end;
/
update labuser.dl_acct set balance = balance - 1 where id = 2;
prompt SESSION A acquired id=2, A was not the deadlock victim
commit;
exit

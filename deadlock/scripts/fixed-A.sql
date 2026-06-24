-- FIX session A: update in canonical order id=1 then id=2.
set echo on feedback on time on define off
alter session set container = FREEPDB1;
update labuser.dl_acct set balance = balance - 1 where id = 1;
begin dbms_session.sleep(4); end;
/
update labuser.dl_acct set balance = balance - 1 where id = 2;
prompt FIX A updated 1 then 2, committing to release both rows for B
commit;
exit

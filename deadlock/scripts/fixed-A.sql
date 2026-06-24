-- FIX, session A: update in CANONICAL order — id=1 then id=2.
set echo on feedback on time on
alter session set container = FREEPDB1;
update labuser.dl_acct set balance = balance - 1 where id = 1;
exec dbms_session.sleep(4);                       -- B will simply WAIT on id=1 below
update labuser.dl_acct set balance = balance - 1 where id = 2;
prompt FIX A: updated 1 then 2; committing (releases both rows for B)...
commit;
exit

-- FIX session B: SAME order id=1 then id=2 -> no cycle, just an orderly wait.
set echo on feedback on time on define off
alter session set container = FREEPDB1;
update labuser.dl_acct set balance = balance - 1 where id = 1;
prompt FIX B got id=1 after waiting for A, now reaching for id=2
update labuser.dl_acct set balance = balance - 1 where id = 2;
prompt FIX B updated 1 then 2 with no deadlock
commit;
exit

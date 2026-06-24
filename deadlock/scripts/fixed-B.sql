-- FIX, session B: SAME order — id=1 then id=2 -> no cycle, just an orderly wait.
set echo on feedback on time on
alter session set container = FREEPDB1;
update labuser.dl_acct set balance = balance - 1 where id = 1;   -- blocks on A's id=1, then proceeds
prompt FIX B: got id=1 (waited for A to commit); now id=2...
update labuser.dl_acct set balance = balance - 1 where id = 2;
prompt FIX B: updated 1 then 2 -- NO DEADLOCK.
commit;
exit

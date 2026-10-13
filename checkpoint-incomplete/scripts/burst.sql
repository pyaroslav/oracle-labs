-- The burst: rewrite every row once (a little over 200 MB of redo) and commit.
whenever sqlerror exit failure
set timing on
alter session set container=FREEPDB1;
update ck.t set pad = translate(pad, 'ab', 'ba');
commit;
exit

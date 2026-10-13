-- The burst: rewrite every row once (~225 MB of redo, ~100,000 dirty blocks' worth of changes) and commit.
whenever sqlerror exit failure
set timing on
alter session set container=FREEPDB1;
update ck.t set pad = translate(pad, 'ab', 'ba');
commit;
exit

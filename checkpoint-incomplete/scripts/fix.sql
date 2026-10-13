-- The fix: online redo logs cannot be resized in place, so ADD bigger groups, SWITCH onto them, CHECKPOINT so the
-- old groups go INACTIVE, then DROP the old ones (a CURRENT or ACTIVE group cannot be dropped).
whenever sqlerror exit failure
alter database add logfile group 3 ('/opt/oracle/oradata/FREE/redo03.log') size 512m;
alter database add logfile group 4 ('/opt/oracle/oradata/FREE/redo04.log') size 512m;
alter database add logfile group 5 ('/opt/oracle/oradata/FREE/redo05.log') size 512m;
declare
  n number;
begin
  -- move CURRENT off the old groups
  for i in 1 .. 4 loop
    select count(*) into n from v$log where group# in (1, 2) and status = 'CURRENT';
    exit when n = 0;
    execute immediate 'alter system switch logfile';
  end loop;
  execute immediate 'alter system checkpoint';
  -- wait (max ~60 s) until both old groups are INACTIVE, then drop them
  for i in 1 .. 60 loop
    select count(*) into n from v$log where group# in (1, 2) and status != 'INACTIVE';
    exit when n = 0;
    dbms_session.sleep(1);
  end loop;
  execute immediate 'alter database drop logfile group 1';
  execute immediate 'alter database drop logfile group 2';
end;
/
exit

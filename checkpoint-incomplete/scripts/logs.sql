set lines 120 pages 50
col member for a45
select l.group#, l.bytes / 1048576 as mb, l.status, f.member
  from v$log l join v$logfile f on f.group# = l.group# order by l.group#;
exit

-- check.sql — run as SYSDBA. The pre-go-live check: for each sequence that feeds a key, compare the value it
-- will hand out next with the highest key already in the table. Any BEHIND row will collide on insert.
-- (The list of sequence -> table.column pairs is the cutover runbook's job; here it is one pair.)
set echo off feedback off verify off heading off pagesize 0 linesize 200 trimspool on serveroutput on
alter session set container = FREEPDB1;
set serveroutput on
declare
  type t_map is table of varchar2(200);
  -- owner.sequence => owner.table.column
  m t_map := t_map('NEWSHOP.ORDER_SEQ=>NEWSHOP.ORDERS.ID');
  seq_owner varchar2(128); seq_name varchar2(128); tab_owner varchar2(128); tab_name varchar2(128); col varchar2(128);
  nxt number; mx number; behind number := 0;
begin
  for i in 1 .. m.count loop
    seq_owner := regexp_substr(m(i), '[^.=>]+', 1, 1); seq_name := regexp_substr(m(i), '[^.=>]+', 1, 2);
    tab_owner := regexp_substr(m(i), '[^.=>]+', 1, 3); tab_name := regexp_substr(m(i), '[^.=>]+', 1, 4);
    col       := regexp_substr(m(i), '[^.=>]+', 1, 5);
    select last_number into nxt from dba_sequences where sequence_owner = seq_owner and sequence_name = seq_name;
    execute immediate 'select nvl(max(' || col || '), 0) from ' || tab_owner || '.' || tab_name into mx;
    dbms_output.put_line(rpad(seq_owner || '.' || seq_name, 22) || ' next=' || nxt || '  max(' || tab_name || '.' || col || ')=' || mx
                         || case when nxt <= mx then '  BEHIND by ' || (mx - nxt + 1) else '  ok' end);
    if nxt <= mx then behind := behind + 1; end if;
  end loop;
  dbms_output.put_line('BEHIND_COUNT=' || behind);
end;
/
exit

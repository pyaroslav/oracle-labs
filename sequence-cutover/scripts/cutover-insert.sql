-- cutover-insert.sql — run as SYSDBA. The first order on the NEW system, exactly as the app would write it.
set echo off feedback off verify off heading off pagesize 0 linesize 200 trimspool on
alter session set container = FREEPDB1;
set serveroutput on
declare
  new_id number;
begin
  insert into newshop.orders values (newshop.order_seq.nextval, 'first order after cutover', sysdate)
    returning id into new_id;
  commit;
  dbms_output.put_line('INSERT=OK');
  dbms_output.put_line('NEW_ID=' || new_id);
exception
  when dup_val_on_index then
    rollback;
    dbms_output.put_line('INSERT=ORA-00001');
    dbms_output.put_line('ERR=' || substr(sqlerrm, 1, 120));
end;
/
exit

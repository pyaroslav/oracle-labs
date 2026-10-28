-- An app server's pooled connection, opened before the change and still in use after it
set heading off feedback off pages 0
select 'HELD_SID=' || sys_context('userenv', 'sid') from dual;
exec dbms_session.sleep(20)
select 'HELD_STILL_ALIVE' from dual;
exit

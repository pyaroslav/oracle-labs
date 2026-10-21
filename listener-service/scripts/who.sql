-- Run by every test connection: which service and container did we land in?
set heading off feedback off pages 0
select 'SVC=' || sys_context('userenv', 'service_name') || ' CON=' || sys_context('userenv', 'con_name') from dual;
exit

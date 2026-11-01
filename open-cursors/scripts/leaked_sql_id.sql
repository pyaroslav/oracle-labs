set pages 0 feedback off
alter session set container = FREEPDB1;
select 'SQLID=' || sql_id from v$sql
where sql_text like 'SELECT ID, CREATED FROM APP.ORDERS WHERE CUSTOMER_ID = :B1%' and rownum = 1;
exit

-- The connector's LogMiner user, per the Debezium 3.4 Oracle connector documentation.
whenever sqlerror continue
alter session set container = CDB$ROOT;
drop user c##dbzuser cascade;
create user c##dbzuser identified by dbz container=all;
alter user c##dbzuser quota unlimited on users container=all;
grant create session to c##dbzuser container=all;
grant set container to c##dbzuser container=all;
grant select on v_$database to c##dbzuser container=all;
grant flashback any table to c##dbzuser container=all;
grant select any table to c##dbzuser container=all;
grant select_catalog_role to c##dbzuser container=all;
grant execute_catalog_role to c##dbzuser container=all;
grant select any transaction to c##dbzuser container=all;
grant logmining to c##dbzuser container=all;
grant create table to c##dbzuser container=all;
grant lock any table to c##dbzuser container=all;
grant create sequence to c##dbzuser container=all;
grant execute on dbms_logmnr to c##dbzuser container=all;
grant execute on dbms_logmnr_d to c##dbzuser container=all;
grant select on v_$log to c##dbzuser container=all;
grant select on v_$log_history to c##dbzuser container=all;
grant select on v_$logmnr_logs to c##dbzuser container=all;
grant select on v_$logmnr_contents to c##dbzuser container=all;
grant select on v_$logmnr_parameters to c##dbzuser container=all;
grant select on v_$logfile to c##dbzuser container=all;
grant select on v_$archived_log to c##dbzuser container=all;
grant select on v_$archive_dest_status to c##dbzuser container=all;
grant select on v_$transaction to c##dbzuser container=all;
grant select on v_$mystat to c##dbzuser container=all;
grant select on v_$statname to c##dbzuser container=all;
exit

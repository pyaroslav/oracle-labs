-- Take the extra 288 MB back: TEMP_SMALL returns to its original 32 MB. Dropping a tempfile is online too.
whenever sqlerror exit failure
alter session set container=FREEPDB1;
alter tablespace temp_small drop tempfile '/opt/oracle/oradata/FREE/FREEPDB1/temp_small02.dbf';
exit

-- The usual first response: give TEMP more room. 32 MB -> 320 MB (10x), online.
whenever sqlerror exit failure
alter session set container=FREEPDB1;
alter tablespace temp_small add tempfile '/opt/oracle/oradata/FREE/FREEPDB1/temp_small02.dbf' size 288m autoextend off;
exit

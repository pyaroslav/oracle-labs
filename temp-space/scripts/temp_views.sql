-- What TEMP_SMALL looks like right after the failure, through three different views. KEY=value lines for run.sh.
set heading off feedback off pages 0 lines 200
alter session set container=FREEPDB1;
select 'TEMPSEG_ROWS=' || count(*) from v$tempseg_usage where tablespace = 'TEMP_SMALL';
select 'HDR_USED_MB=' || round(sum(bytes_used) / 1048576) from v$temp_space_header where tablespace_name = 'TEMP_SMALL';
select 'HDR_FREE_MB=' || round(sum(bytes_free) / 1048576) from v$temp_space_header where tablespace_name = 'TEMP_SMALL';
select 'SORTSEG_USED_MB=' || round(used_blocks * 8192 / 1048576) from v$sort_segment where tablespace_name = 'TEMP_SMALL';
select 'FREESPACE_MB=' || round(free_space / 1048576) from dba_temp_free_space where tablespace_name = 'TEMP_SMALL';
select 'SIZE_MB=' || round(tablespace_size / 1048576) from dba_temp_free_space where tablespace_name = 'TEMP_SMALL';
exit

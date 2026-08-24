-- undrop.sql — recover a dropped table from the recycle bin with FLASHBACK TABLE ... TO BEFORE DROP.
-- Run as LABUSER in FREEPDB1 (the recycle bin is per-user). Emits signals for run.sh.
set echo off feedback off verify off heading off pagesize 0 linesize 200 trimspool on

select 'ROWS_BEFORE='||count(*) from accounts;

-- the mistake: drop the table outright
drop table accounts;
select 'EXISTS_AFTER_DROP='||count(*) from user_tables where table_name = 'ACCOUNTS';

-- recovery: bring it back from the recycle bin, rows and all
flashback table accounts to before drop;
select 'EXISTS_AFTER_FLASHBACK='||count(*) from user_tables where table_name = 'ACCOUNTS';
select 'ROWS_AFTER='||count(*) from accounts;
exit

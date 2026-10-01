-- probe.sql — run as APP over TCP (//localhost:1521/FREEPDB1), i.e. a real network session, while the sidecar
-- captures port 1521. Reads the confidential rows, then reports what this session negotiated on the wire.
set echo off feedback off verify off heading off pagesize 0 linesize 200 trimspool on
prompt >>>SIGNALS
select 'ROWS='||count(*) from vault where secret like 'CANARY-%';
select 'SECRET='||secret from vault where id = 1;
select 'ENC='||nvl(max(case when network_service_banner like 'AES%Encryption service adapter%'
                             then regexp_substr(network_service_banner, '^\S+') end), 'NONE')
  from v$session_connect_info where sid = sys_context('userenv', 'sid');
select 'CKSUM='||nvl(max(case when network_service_banner like 'SHA%Crypto-checksumming service adapter%'
                               then regexp_substr(network_service_banner, '^\S+') end), 'NONE')
  from v$session_connect_info where sid = sys_context('userenv', 'sid');
prompt >>>ENDSIGNALS
exit

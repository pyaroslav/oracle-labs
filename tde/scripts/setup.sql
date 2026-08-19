-- setup.sql — configure a TDE software keystore, then build one ENCRYPTED tablespace and one ORDINARY
-- tablespace holding identical "canary" rows. Run as SYSDBA. Idempotent (safe to re-run).
--
-- WALLET_ROOT is a static parameter, so setting it needs one restart; everything after that is online.
-- The canary string is deliberately distinctive so `strings <datafile> | grep` finds it in plaintext.
set echo off feedback off verify off
whenever sqlerror continue

-- === point TDE at a keystore location (static -> requires a restart), then turn on the FILE keystore ===
alter system set wallet_root = '/opt/oracle/oradata/wallet' scope = spfile;
shutdown immediate
startup
alter pluggable database all open;
alter system set tde_configuration = 'KEYSTORE_CONFIGURATION=FILE' scope = both;

-- === create + open the software keystore (CDB), set the CDB master key ===
administer key management create keystore identified by "Lab_Passw0rd1";
administer key management set keystore open identified by "Lab_Passw0rd1" container = all;
administer key management set key identified by "Lab_Passw0rd1" with backup container = all;

-- === set a master key inside the PDB, where the encrypted tablespace will live ===
alter session set container = FREEPDB1;
administer key management set keystore open identified by "Lab_Passw0rd1";
administer key management set key identified by "Lab_Passw0rd1" with backup;

-- clean slate (needs the keystore open to drop an encrypted tablespace) -----------------------------
begin execute immediate 'drop user app cascade'; exception when others then null; end;
/
begin execute immediate 'drop tablespace tde_enc including contents and datafiles'; exception when others then null; end;
/
begin execute immediate 'drop tablespace tde_plain including contents and datafiles'; exception when others then null; end;
/

-- === one ENCRYPTED tablespace (AES256) and one ORDINARY tablespace, at known datafile paths ===
create tablespace tde_enc
  datafile '/opt/oracle/oradata/FREE/FREEPDB1/tde_enc.dbf' size 50m
  encryption using 'AES256' default storage (encrypt);
create tablespace tde_plain
  datafile '/opt/oracle/oradata/FREE/FREEPDB1/tde_plain.dbf' size 50m;

create user app identified by "Lab_Passw0rd1"
  quota unlimited on tde_enc quota unlimited on tde_plain;
grant create session, create table to app;

-- identical rows in both: a fixed CANARY marker + fake card numbers. 2,000 rows each is plenty to spot.
create table app.secrets_enc   (id number, holder varchar2(40), card varchar2(40)) tablespace tde_enc;
create table app.secrets_plain (id number, holder varchar2(40), card varchar2(40)) tablespace tde_plain;

insert into app.secrets_enc
  select rownum, 'CANARY_TDE_7F3A9B2E1D', '4111-1111-1111-'||lpad(mod(rownum,10000),4,'0')
  from dual connect by level <= 2000;
insert into app.secrets_plain
  select rownum, 'CANARY_TDE_7F3A9B2E1D', '4111-1111-1111-'||lpad(mod(rownum,10000),4,'0')
  from dual connect by level <= 2000;
commit;

-- force the blocks out of the buffer cache and onto disk so reading the raw datafile is meaningful
alter system checkpoint;
alter system flush buffer_cache;
exit

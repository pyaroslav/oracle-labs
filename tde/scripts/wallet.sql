-- wallet.sql — the second half of the story: with the datafiles safe on disk, what happens to the
-- DATABASE when the keystore is closed? Close the wallet, try to read both tables, then reopen and read
-- again. The encrypted table becomes unreadable while the wallet is shut; the plaintext one is unaffected.
-- Run as SYSDBA. Emits CLOSED_READ / CLOSED_PLAIN / OPEN_READ markers for run.sh.
set echo off feedback off verify off
alter session set container = FREEPDB1;
set serveroutput on   -- MUST come AFTER the container switch: SQL*Plus serveroutput doesn't carry into the new PDB
alter system flush buffer_cache;   -- drop cached blocks so a read must touch the encrypted datafile

-- CLOSE the keystore: the master key leaves memory, so encrypted blocks can no longer be decrypted
administer key management set keystore close identified by "Lab_Passw0rd1";

declare n number;
begin
  select count(*) into n from app.secrets_enc;
  dbms_output.put_line('CLOSED_READ=READABLE_'||n);          -- if this prints, encryption did NOT protect the read
exception when others then
  dbms_output.put_line('CLOSED_READ=BLOCKED_'||sqlcode);     -- expected: ORA-28365 wallet is not open
end;
/

declare n number;
begin
  select count(*) into n from app.secrets_plain;
  dbms_output.put_line('CLOSED_PLAIN=READABLE_'||n);         -- plaintext tablespace is unaffected
exception when others then
  dbms_output.put_line('CLOSED_PLAIN=BLOCKED_'||sqlcode);
end;
/

-- REOPEN the keystore: access returns, no data lost
administer key management set keystore open identified by "Lab_Passw0rd1";

declare n number;
begin
  select count(*) into n from app.secrets_enc;
  dbms_output.put_line('OPEN_READ=READABLE_'||n);
exception when others then
  dbms_output.put_line('OPEN_READ=BLOCKED_'||sqlcode);
end;
/
exit

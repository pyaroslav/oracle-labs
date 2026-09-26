-- setup.sql -- build the character-set migration lab: a customers table in the AL32UTF8 (Unicode) database
-- with a realistic mix of names, half plain ASCII and half containing non-ASCII characters (Latin accents and
-- CJK). The names are built with UNISTR('\xxxx') from Unicode code points so this script file stays pure ASCII
-- and portable -- the multibyte data is created server-side, not carried in the file. Run as SYSDBA; switch
-- into the PDB first. NOTE: SQL*Plus treats a trailing '-' as line continuation, so marker lines never end in
-- a hyphen; 'set define off' keeps '\' escapes and any '&' out of SQL*Plus substitution; and no statement
-- carries a trailing inline comment (a '-- ...' after the ';' trips SQL*Plus here with ORA-03405).
set echo off feedback off verify off heading off pagesize 0 linesize 200 trimspool on define off
alter session set container = FREEPDB1;

begin execute immediate 'drop user csmig cascade'; exception when others then null; end;
/
create user csmig identified by "Lab_Passw0rd1" quota unlimited on users;
grant create session, create table to csmig;
create table csmig.customers (id number, name varchar2(60));

-- 5 plain-ASCII names
insert into csmig.customers values (1,  'Smith');
insert into csmig.customers values (2,  'Johnson');
insert into csmig.customers values (3,  'Brown');
insert into csmig.customers values (4,  'Davis');
insert into csmig.customers values (5,  'Lee');

-- 5 names with non-ASCII characters, built from Unicode code points and stored as UTF-8 in the AL32UTF8 DB:
--   6 Jose (e-acute \00E9)   7 Muller (u-umlaut \00FC)   8 Renee (e-acute \00E9)
--   9 Francois (c-cedilla \00E7)   10 CJK name Tanaka (\7530\4E2D)
insert into csmig.customers values (6,  unistr('Jos\00E9'));
insert into csmig.customers values (7,  unistr('M\00FCller'));
insert into csmig.customers values (8,  unistr('Ren\00E9e'));
insert into csmig.customers values (9,  unistr('Fran\00E7ois'));
insert into csmig.customers values (10, unistr('\7530\4E2D'));
commit;
exit

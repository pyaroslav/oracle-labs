-- DRILL 1 — Human-error recovery.  "Replication is not a backup."
-- A Data Guard standby would have faithfully replicated both mistakes below within seconds.
-- These local, point-in-time features are what actually save you. Run as labuser in FREEPDB1.
set echo on
set feedback on

prompt
prompt ============================================================
prompt  A) Accidental DELETE + COMMIT  -> recover with Flashback Query
prompt ============================================================
select count(*) as orders_before from orders;

-- capture a precise marker (SCN) just before the mistake
variable v_scn number
begin :v_scn := dbms_flashback.get_system_change_number; end;
/

-- the "mistake": a committed DELETE with no WHERE clause
delete from orders;
commit;
select count(*) as after_delete from orders;

-- recovery: read the rows AS OF the captured SCN and put them back
insert into orders (id, customer, amount, created)
select id, customer, amount, created
from   orders as of scn :v_scn;
commit;
select count(*) as after_flashback_query_recovery from orders;

prompt
prompt ============================================================
prompt  B) Accidental DROP TABLE  -> recover with Flashback Table TO BEFORE DROP
prompt ============================================================
drop table orders;
-- (the table is now gone; a standby would have dropped its copy too)
flashback table orders to before drop;
select count(*) as after_undrop from orders;

prompt
prompt Drill 1 complete: the database was restored to its pre-mistake state
prompt without any standby involved.

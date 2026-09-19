-- churn.sql — the reproduction, run identically before and after the fix. Open a full-scan cursor (no ORDER
-- BY, so rows come back lazily block by block), fetch ONE row to pin the read-consistent snapshot, then rewrite
-- every row 12 times and commit -- churning far more undo than the tiny undo tablespace holds. Then keep
-- fetching the pre-churn snapshot: on the weak config the undo it needs has been overwritten -> ORA-01555; on
-- the fixed config (guaranteed retention, ample undo) the undo is preserved -> the query finishes. The outcome
-- (SNAP_1555 = YES/NO, rows fetched, error code) is written to snap.result and emitted as signals.
set echo off feedback off verify off heading off pagesize 0 linesize 200 serveroutput off trimspool on
alter session set container = FREEPDB1;

declare
  cursor c is select id, pad from snap.t;   -- plain full scan: fetched lazily, block by block
  v_id   number;
  v_pad  varchar2(200);
  n      number := 0;
  v_code number;
begin
  delete from snap.result; commit;
  open c;
  fetch c into v_id, v_pad;                  -- pin the read-consistent snapshot (as of this SCN)
  n := 1;
  for i in 1..12 loop                        -- churn: rewrite all 20,000 rows repeatedly, overwriting undo
    update snap.t set pad = lpad(to_char(i), 200, 'y');
    commit;
  end loop;
  loop                                       -- keep reading the OLD snapshot -> needs the overwritten undo
    fetch c into v_id, v_pad;
    exit when c%notfound;
    n := n + 1;
  end loop;
  close c;
  insert into snap.result values ('SNAP_1555', 'NO');
  insert into snap.result values ('ROWS', to_char(n));
  insert into snap.result values ('ERR', '0');
  commit;
exception
  when others then
    v_code := sqlcode;
    insert into snap.result values ('SNAP_1555', case when v_code = -1555 then 'YES' else 'NO' end);
    insert into snap.result values ('ROWS', to_char(n));
    insert into snap.result values ('ERR', to_char(v_code));
    commit;
end;
/

prompt >>>SIGNALS
select 'SNAP_1555='||v from snap.result where k = 'SNAP_1555';
select 'ROWS='||v      from snap.result where k = 'ROWS';
select 'ERR='||v       from snap.result where k = 'ERR';
prompt >>>ENDSIGNALS
exit

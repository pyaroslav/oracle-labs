-- read.sql — run as REP_EAST, REP_WEST, or MGR (connects straight to the PDB service as the user). Reports
-- how many rows THIS session can see, which regions those rows are in, the SUM of amounts (proving the VPD
-- predicate is applied to AGGREGATES, not just row listings), and a targeted lookup of a known WEST row by
-- id (id=3) — proving a rep cannot reach another region's row even by asking for it directly. Emits one
-- KEY=VALUE line per fact for run.sh to assert.
--
-- The point: VPD appends its predicate to the BASE TABLE for every statement. There is no view to bypass and
-- no way to widen the result — count, sum, and a by-id probe are all confined to the session's own rows.
set heading off pagesize 0 feedback off verify off
prompt >>>SIGNALS
select 'WHOAMI='||user from dual;
select 'ROWS='||count(*) from vpdown.orders;
select 'REGIONS='||listagg(region,',') within group (order by region)
  from (select distinct region from vpdown.orders);
select 'SUMAMT='||nvl(sum(amount),0) from vpdown.orders;
select 'PICKWEST='||count(*) from vpdown.orders where id = 3;
prompt >>>ENDSIGNALS
exit

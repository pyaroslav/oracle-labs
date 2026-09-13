-- probe.sql — run five queries with GATHER_PLAN_STATISTICS and, after each, read the access operation
-- (from V$SQL_PLAN) and the buffer gets (from V$SQL) for that exact cursor. Run as SYSDBA in FREEPDB1.
-- Pattern (reused from the execution-plans / partition-pruning labs): after a query, PREV_SQL_ID in
-- V$SESSION points at it; capture it into a SQL*Plus variable immediately, then read the plan/stats by that
-- id so later statements don't clobber it. Emits KEY=VALUE lines for run.sh; markers must not end in '-'.
set echo off feedback off verify off pagesize 0 linesize 400 trimspool on
alter session set container = FREEPDB1;

column mysid new_value MYSID noprint
select sys_context('userenv','sid') mysid from dual;

prompt >>>SIGNALS

-- Q1: selective predicate, natural plan -> the optimizer should pick idx_cust (index range scan) -----
select /*+ gather_plan_statistics */ count(amount) from shop.orders o where o.customer_id = 500;
column ps new_value PS noprint
column pc new_value PC noprint
select prev_sql_id ps, prev_child_number pc from v$session where sid = &MYSID;
select 'HELPS_IDX_OP='||listagg(operation||decode(options, null, '', ' '||options), ';') within group (order by id)
  from v$sql_plan where sql_id = '&PS' and child_number = &PC and (operation like 'TABLE ACCESS%' or operation like 'INDEX%');
select 'HELPS_IDX_BUF='||buffer_gets from v$sql where sql_id = '&PS' and child_number = &PC;

-- Q2: same selective predicate, FORCED full scan -> the cost of NOT having/using the index -----------
select /*+ gather_plan_statistics full(o) */ count(amount) from shop.orders o where o.customer_id = 500;
select prev_sql_id ps, prev_child_number pc from v$session where sid = &MYSID;
select 'HELPS_FULL_BUF='||buffer_gets from v$sql where sql_id = '&PS' and child_number = &PC;

-- Q3: common value (SHIPPED, 95%), natural plan -> the optimizer should IGNORE idx_status (full scan) -
select /*+ gather_plan_statistics */ count(amount) from shop.orders o where o.status = 'SHIPPED';
select prev_sql_id ps, prev_child_number pc from v$session where sid = &MYSID;
select 'SHIPPED_OP='||listagg(operation||decode(options, null, '', ' '||options), ';') within group (order by id)
  from v$sql_plan where sql_id = '&PS' and child_number = &PC and (operation like 'TABLE ACCESS%' or operation like 'INDEX%');
select 'SHIPPED_BUF='||buffer_gets from v$sql where sql_id = '&PS' and child_number = &PC;

-- Q4: common value, FORCED to use idx_status -> reading 95% of rows via the index HURTS --------------
select /*+ gather_plan_statistics index(o idx_status) */ count(amount) from shop.orders o where o.status = 'SHIPPED';
select prev_sql_id ps, prev_child_number pc from v$session where sid = &MYSID;
select 'SHIPPED_FORCED_OP='||listagg(operation||decode(options, null, '', ' '||options), ';') within group (order by id)
  from v$sql_plan where sql_id = '&PS' and child_number = &PC and (operation like 'TABLE ACCESS%' or operation like 'INDEX%');
select 'SHIPPED_FORCED_BUF='||buffer_gets from v$sql where sql_id = '&PS' and child_number = &PC;

-- Q5: rare value (PENDING, 0.1%), natural plan -> the SAME index is now USED (index range scan) ------
select /*+ gather_plan_statistics */ count(amount) from shop.orders o where o.status = 'PENDING';
select prev_sql_id ps, prev_child_number pc from v$session where sid = &MYSID;
select 'PENDING_OP='||listagg(operation||decode(options, null, '', ' '||options), ';') within group (order by id)
  from v$sql_plan where sql_id = '&PS' and child_number = &PC and (operation like 'TABLE ACCESS%' or operation like 'INDEX%');
select 'PENDING_BUF='||buffer_gets from v$sql where sql_id = '&PS' and child_number = &PC;

prompt >>>ENDSIGNALS
exit

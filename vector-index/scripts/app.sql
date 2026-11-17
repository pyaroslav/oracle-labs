-- Vector index lab schema (run in FREEPDB1 as SYSDBA). Deterministic: DBMS_RANDOM with fixed seeds, no model.
--   APP.DOCS     100,000 x VECTOR(128, FLOAT32) in 100 clusters (a centroid + small noise): what real embeddings
--                of similar documents look like. APP.QUERIES: 20 query vectors near clusters.
--   APP.RND      100,000 x VECTOR(128, FLOAT32), uniform random: the hard case for an approximate index.
--                APP.RND_QUERIES: 20 uniform random query vectors.
--   APP.RECALL10 how many of the exact top 10 an approximate query found, in % over the 20 queries.
whenever sqlerror exit failure
declare n number; begin select count(*) into n from dba_users where username = 'APP'; if n > 0 then
  for s in (select sid, serial# from v$session where username = 'APP') loop
    execute immediate 'alter system kill session ''' || s.sid || ',' || s.serial# || ''' immediate'; end loop;
  execute immediate 'drop user app cascade'; end if; end;
/
create user app identified by App_Passw0rd1 quota unlimited on users;
grant db_developer_role, create session to app;
create table app.docs (id number primary key, cluster_id number, emb vector(128, float32));
create table app.queries (qid number primary key, emb vector(128, float32));
create table app.rnd (id number primary key, emb vector(128, float32));
create table app.rnd_queries (qid number primary key, emb vector(128, float32));

declare
  type t_num is table of number index by pls_integer;
  type t_str is table of varchar2(32767) index by pls_integer;
  type t_cent is table of sys.odcinumberlist index by pls_integer;
  c t_cent; ids t_num; cls t_num; vs t_str; k pls_integer; v varchar2(32767);
  function fmt(x number) return varchar2 is
  begin return to_char(round(x, 4), 'FM990.0000', 'nls_numeric_characters=''.,'''); end;
  function near(ci pls_integer) return varchar2 is
    s varchar2(32767) := '[';
  begin
    for d in 1 .. 128 loop s := s || fmt(c(ci)(d) + dbms_random.value(-0.35, 0.35)) || case when d < 128 then ',' end; end loop;
    return s || ']';
  end;
  function uniform return varchar2 is
    s varchar2(32767) := '[';
  begin
    for d in 1 .. 128 loop s := s || fmt(dbms_random.value(-1, 1)) || case when d < 128 then ',' end; end loop;
    return s || ']';
  end;
begin
  -- clustered
  dbms_random.seed(42);
  for i in 1 .. 100 loop
    c(i) := sys.odcinumberlist(); c(i).extend(128);
    for d in 1 .. 128 loop c(i)(d) := round(dbms_random.value(-1, 1), 4); end loop;
  end loop;
  k := 0;
  for r in 1 .. 100000 loop
    k := k + 1; ids(k) := r; cls(k) := mod(r - 1, 100) + 1; vs(k) := near(cls(k));
    if k = 1000 then
      forall j in 1 .. k insert into app.docs values (ids(j), cls(j), to_vector(vs(j), 128, float32));
      commit; k := 0;
    end if;
  end loop;
  for q in 1 .. 20 loop
    v := near(mod(q * 37, 100) + 1);
    insert into app.queries values (q, to_vector(v, 128, float32));
  end loop;
  -- uniform
  dbms_random.seed(7);
  k := 0;
  for r in 1 .. 100000 loop
    k := k + 1; ids(k) := r; vs(k) := uniform;
    if k = 1000 then
      forall j in 1 .. k insert into app.rnd values (ids(j), to_vector(vs(j), 128, float32));
      commit; k := 0;
    end if;
  end loop;
  for q in 1 .. 20 loop v := uniform; insert into app.rnd_queries values (q, to_vector(v, 128, float32)); end loop;
  commit;
end;
/

create or replace function app.recall10(p_tab varchar2, p_qtab varchar2, p_fetch varchar2) return number is
  type t is table of number;
  ex t; ap t; hits number := 0;
  type rc is ref cursor; cq rc; qid number; qv vector;
begin
  open cq for 'select qid, emb from app.' || p_qtab || ' order by qid';
  loop
    fetch cq into qid, qv; exit when cq%notfound;
    execute immediate 'select id from (select id from app.' || p_tab
      || ' order by vector_distance(emb, :q, cosine) fetch exact first 10 rows only)' bulk collect into ex using qv;
    execute immediate 'select id from (select id from app.' || p_tab
      || ' order by vector_distance(emb, :q, cosine) ' || p_fetch || ')' bulk collect into ap using qv;
    for i in 1 .. ap.count loop if ap(i) member of ex then hits := hits + 1; end if; end loop;
  end loop;
  close cq;
  return round(hits / 200 * 100, 1);
end;
/
exec dbms_stats.gather_schema_stats('APP')

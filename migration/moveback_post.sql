-- Move back, step 4b: run on the OLD project (rqhwzbrcgnpxtuaeoxml) right after the
-- Singapore data has been loaded into it. Needs psql variables from_ref and to_ref.
\set ON_ERROR_STOP on
select set_config('migr.from_ref', :'from_ref', false), set_config('migr.to_ref', :'to_ref', false);

-- Stored image/audio URLs: Singapore ref -> old ref, in every text/json column (triggers off).
set session_replication_role = replica;
do $$
declare r record; n bigint; v_from text := current_setting('migr.from_ref'); v_to text := current_setting('migr.to_ref');
begin
  for r in
    select c.table_name, c.column_name, c.data_type, c.udt_name
    from information_schema.columns c
    join information_schema.tables t using (table_schema, table_name)
    where c.table_schema = 'public' and t.table_type = 'BASE TABLE'
      and c.data_type in ('text', 'character varying', 'jsonb', 'json', 'ARRAY')
      and c.is_generated = 'NEVER'
  loop
    execute format(
      'update public.%I set %I = replace(%I::text, %L, %L)::%s where %I::text like %L',
      r.table_name, r.column_name, r.column_name, v_from, v_to,
      case when r.data_type = 'ARRAY' then format('%I', r.udt_name) when r.data_type = 'character varying' then 'varchar' else r.data_type end,
      r.column_name, '%' || v_from || '%');
    get diagnostics n = row_count;
    if n > 0 then raise notice 'url rewrite: %.% -> % rows', r.table_name, r.column_name, n; end if;
  end loop;
end $$;
set session_replication_role = origin;

-- Caches start empty
delete from public.top_fans_cache;
delete from public.campaign_list_cache;

-- push_subscriptions are KEPT: they were made with the current VAPID key, which send-push on
-- this project is switched to in the last step.

analyze;

-- leftovers check: should be 0
select 'functions still pointing at Singapore' as check, count(*) from pg_proc
 where pronamespace = 'public'::regnamespace and prosrc like '%' || current_setting('migr.from_ref') || '%';

-- Step 3d: run on the NEW project after schema + data are restored.
-- Needs psql variables old_ref and new_ref (2_import.ps1 passes them).
\set ON_ERROR_STOP on
select set_config('migr.old_ref', :'old_ref', false), set_config('migr.new_ref', :'new_ref', false);

-- 1) Realtime: same tables as the old project
do $$
declare t text;
begin
  foreach t in array array['ranking_monthly','posts','comments','notifications','realtime_ping'] loop
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;

-- 2) Stored image/audio URLs: old project ref -> new project ref, in every text/json column.
--    Triggers are off for this step so no notifications/push fire.
set session_replication_role = replica;
do $$
declare r record; n bigint; v_old text := current_setting('migr.old_ref'); v_new text := current_setting('migr.new_ref');
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
      r.table_name, r.column_name, r.column_name, v_old, v_new,
      case when r.data_type = 'ARRAY' then format('%I', r.udt_name) when r.data_type = 'character varying' then 'varchar' else r.data_type end,
      r.column_name, '%' || v_old || '%');
    get diagnostics n = row_count;
    if n > 0 then raise notice 'url rewrite: %.% -> % rows', r.table_name, r.column_name, n; end if;
  end loop;
end $$;
set session_replication_role = origin;

-- 3) Caches start empty (they hold old URLs)
delete from public.top_fans_cache;
delete from public.campaign_list_cache;

-- 3b) Web Push uses a NEW VAPID key pair in the new project; subscriptions made with the old
--     key can't receive pushes any more (and would fail with 403, which send-push doesn't
--     auto-remove). Users turn notifications on again from the Notification page.
delete from public.push_subscriptions;

-- 4) Cron jobs (same names, schedules and commands as the old project)
select cron.schedule('auto-champ-of-the-month-daily', '10 17 * * *',     'select public.auto_record_champ_of_the_month();');
select cron.schedule('shop-open-notify',              '*/5 * * * *',     'select public.check_shop_open_notifications();');
select cron.schedule('cleanup-old-notifications',     '*/15 * * * *',    'select public.cleanup_old_notifications();');
select cron.schedule('settle-member-campaigns',       '*/5 * * * *',     'select public.settle_due_member_campaigns();');
select cron.schedule('take-vote-checkpoints',         '* * * * *',       'select public.take_due_vote_checkpoints();');
select cron.schedule('auto-open-birthday-campaigns',  '1,31 17 * * *',   'select public.auto_open_birthday_campaigns();');
select cron.schedule('like_rules_drip',               '2-59/5 * * * *',  'select public._like_rules_tick(2)');
select cron.schedule('monthly-cookie-reminder',       '0 2 1 * *',       'select public.remind_monthly_cookie();');
select cron.schedule('auto-daily-accounts',           '50 16 * * *',     'select public.run_auto_daily_accounts();');

-- 5) Fresh planner stats
analyze;

-- leftovers check: should be 0 rows
select 'functions still pointing at old project' as check, count(*) from pg_proc
 where pronamespace = 'public'::regnamespace and prosrc like '%' || current_setting('migr.old_ref') || '%';

-- keep API access on the new project (default Supabase grant)
grant usage on schema public to anon, authenticated, service_role;

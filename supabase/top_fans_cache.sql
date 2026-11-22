-- get_top_fans() was the 2nd-heaviest query in the DB (~400 ms x 93k calls): it re-aggregated
-- the whole fan_logs table on every Home page load. Now the result is cached for 60 s in
-- top_fans_cache; only one caller recomputes when it goes stale (advisory lock), everyone else
-- gets the cached copy. Same JSON shape as before, so index.html needs no change.

create table if not exists public.top_fans_cache (
  id int primary key default 1 check (id = 1),
  data jsonb not null,
  computed_at timestamptz not null default now()
);
alter table public.top_fans_cache enable row level security;
revoke all on public.top_fans_cache from anon, authenticated;

-- the original query, unchanged
create or replace function public._compute_top_fans()
returns jsonb
language sql
security definer
set search_path to 'public'
as $function$
  select coalesce(jsonb_object_agg(member_name, fans), '{}'::jsonb)
  from (
    select member_name, jsonb_agg(jsonb_build_object(
      'username', username,
      'name', name,
      'img', img,
      'total', total
    ) order by total desc) as fans
    from (
      select
        fl.member_name,
        fl.username,
        public.disp_name(fl.username, coalesce(u.name, fl.username)) as name,
        public.disp_img(fl.username, u.profile_img) as img,
        sum(fl.amount) as total
      from public.fan_logs fl
      left join public.users u on u.username = fl.username
      where fl.username not in (select username from public.fan_board_hidden_users)
      group by fl.member_name, fl.username, coalesce(u.name, fl.username), u.profile_img
    ) grouped
    group by member_name
  ) per_member;
$function$;
revoke all on function public._compute_top_fans() from public, anon, authenticated;

create or replace function public.get_top_fans()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_data jsonb;
  v_at timestamptz;
begin
  select data, computed_at into v_data, v_at from public.top_fans_cache where id = 1;

  if v_data is not null and v_at > now() - interval '60 seconds' then
    return v_data;
  end if;

  -- stale or empty: one caller recomputes, the others return the stale copy meanwhile
  if pg_try_advisory_xact_lock(hashtext('get_top_fans_cache')) then
    v_data := public._compute_top_fans();
    insert into public.top_fans_cache (id, data, computed_at)
    values (1, v_data, now())
    on conflict (id) do update set data = excluded.data, computed_at = excluded.computed_at;
    return v_data;
  end if;

  return coalesce(v_data, public._compute_top_fans());
end;
$function$;

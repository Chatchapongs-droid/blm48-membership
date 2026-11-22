-- get_active_member_campaigns / get_ended_member_campaigns recomputed every campaign's supporter
-- count (wallet_logs + likes + comments + comment_likes) on each call: ~110 ms idle, ~320-530 ms
-- under real traffic, called from index.html + campaign.html. Now cached 30 s per list.
-- Any change to member_campaigns or campaign_hidden_supporters clears the cache immediately,
-- so admin actions (open/settle/cover/banner/hide supporter) still show at once; only the live
-- cookie totals / supporter counts can lag by up to 30 s. Same JSON as before.

create table if not exists public.campaign_list_cache (
  kind text primary key check (kind in ('active', 'ended')),
  data jsonb not null,
  computed_at timestamptz not null default now()
);
alter table public.campaign_list_cache enable row level security;
revoke all on public.campaign_list_cache from anon, authenticated;

-- original queries, unchanged
create or replace function public._compute_active_member_campaigns()
returns jsonb language sql stable security definer set search_path to 'public'
as $function$
  select coalesce(jsonb_agg(public._campaign_json(c)
    order by (c.end_at > now()) desc, public._campaign_total(c) desc, c.started_at asc), '[]'::jsonb)
  from public.member_campaigns c
  where c.end_at > now() - interval '7 days';
$function$;

create or replace function public._compute_ended_member_campaigns()
returns jsonb language sql stable security definer set search_path to 'public'
as $function$
  select coalesce(jsonb_agg(public._campaign_json(c) order by c.end_at desc), '[]'::jsonb)
  from public.member_campaigns c
  where c.status <> 'active' or c.end_at <= now();
$function$;

revoke all on function public._compute_active_member_campaigns() from public, anon, authenticated;
revoke all on function public._compute_ended_member_campaigns() from public, anon, authenticated;

create or replace function public._cached_campaign_list(p_kind text)
returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
declare
  v_data jsonb;
  v_at timestamptz;
begin
  select data, computed_at into v_data, v_at from public.campaign_list_cache where kind = p_kind;
  if v_data is not null and v_at > now() - interval '30 seconds' then
    return v_data;
  end if;

  -- stale/empty: one caller recomputes, concurrent callers get the stale copy meanwhile
  if pg_try_advisory_xact_lock(hashtext('campaign_list_cache:' || p_kind)) or v_data is null then
    v_data := case p_kind when 'active' then public._compute_active_member_campaigns()
                          else public._compute_ended_member_campaigns() end;
    insert into public.campaign_list_cache (kind, data, computed_at)
    values (p_kind, v_data, now())
    on conflict (kind) do update set data = excluded.data, computed_at = excluded.computed_at;
  end if;
  return v_data;
end;
$function$;
revoke all on function public._cached_campaign_list(text) from public, anon, authenticated;

create or replace function public.get_active_member_campaigns()
returns jsonb language sql volatile security definer set search_path to 'public'
as $function$ select public._cached_campaign_list('active'); $function$;

create or replace function public.get_ended_member_campaigns()
returns jsonb language sql volatile security definer set search_path to 'public'
as $function$ select public._cached_campaign_list('ended'); $function$;

-- invalidate on any campaign / hidden-supporter change
create or replace function public._campaign_list_cache_clear()
returns trigger language plpgsql security definer set search_path to 'public'
as $function$
begin
  delete from public.campaign_list_cache;
  return null;
end;
$function$;

drop trigger if exists member_campaigns_cache_clear on public.member_campaigns;
create trigger member_campaigns_cache_clear
  after insert or update or delete on public.member_campaigns
  for each statement execute function public._campaign_list_cache_clear();

drop trigger if exists campaign_hidden_supporters_cache_clear on public.campaign_hidden_supporters;
create trigger campaign_hidden_supporters_cache_clear
  after insert or update or delete on public.campaign_hidden_supporters
  for each statement execute function public._campaign_list_cache_clear();

-- =====================================================================
-- DRAFT — DO NOT RUN YET (2026-11-24)
-- Design: docs/design/2026-11-24_npt48_launch_and_champ_of_the_week.md
-- Covers: app_settings flags, NPT48 visibility helper, ranking_weekly + _credit_member_cookies,
--         champ_of_the_week + auto record + read RPC, group_singles, admin_audit_log.
-- Not covered yet (needs per-function review before writing):
--   * rewriting the 6 NPT48 filters to call member_group_visible()
--   * get_winner_theme / get_champ_thanks_status / create_champ_thanks_post / get_fan_profile changes
--   * soft-delete columns + filters (design A2)
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. app_settings (feature flags / dates, changed without code deploys)
-- ---------------------------------------------------------------------
create table if not exists public.app_settings (
  key        text primary key,
  value      jsonb not null,
  updated_at timestamptz not null default now()
);
alter table public.app_settings enable row level security;
grant select, insert, update, delete on public.app_settings to service_role;

insert into public.app_settings (key, value) values
  ('npt48_full_launch', 'false'::jsonb),
  ('champ_mode', jsonb_build_object(
      'weekly_count_from', '2027-01-03',   -- first Sunday of January: first counted week 3–9 Jan, champ announced Sun 10 Jan
      'transition_from',   '2027-01-01',   -- splash alternates month/week
      'week_only_from',    '2027-02-01'))  -- weekly champ only
on conflict (key) do nothing;

create or replace function public.app_setting(p_key text)
returns jsonb language sql stable security definer set search_path to 'public' as $$
  select value from public.app_settings where key = p_key;
$$;

-- ---------------------------------------------------------------------
-- 2. NPT48 visibility (replace `coalesce(group_name,'BLM48')='BLM48'` with this)
-- ---------------------------------------------------------------------
create or replace function public.member_group_visible(p_group text)
returns boolean language sql stable security definer set search_path to 'public' as $$
  select coalesce(p_group, 'BLM48') = 'BLM48'
      or coalesce((select value = 'true'::jsonb from public.app_settings where key = 'npt48_full_launch'), false);
$$;

-- ---------------------------------------------------------------------
-- 3. Weekly ranking (Sunday 00:00 – Saturday 23:59, Asia/Bangkok)
-- ---------------------------------------------------------------------
create or replace function public._bkk_week_start(p_ts timestamptz default now())
returns date language sql stable set search_path to 'public' as $$
  select d - extract(dow from d)::int   -- dow: Sunday = 0
  from (select (p_ts at time zone 'Asia/Bangkok')::date as d) x;
$$;

create table if not exists public.ranking_weekly (
  member_name text    not null,
  week_start  date    not null,
  cookies     numeric not null default 0,
  primary key (member_name, week_start)
);
create index if not exists ranking_weekly_week_idx on public.ranking_weekly (week_start, cookies desc);
alter table public.ranking_weekly enable row level security;
grant select, insert, update, delete on public.ranking_weekly to service_role;

-- Central cookie credit (design section D). Replaces the earlier ranking_monthly trigger idea:
-- likes/comments must close per WEEK, so the caller passes the post's created_at.
-- To be called by like_post, like_comment, add_comment, give_cookie, send_member_gift,
-- _like_rules_tick, _oshi_like_queue_tick instead of writing ranking_monthly themselves.
-- Before weekly_count_from the caller keeps its old monthly logic (this returns 'legacy').
create or replace function public._credit_member_cookies(p_member text, p_delta numeric,
                                                         p_post_created_at timestamptz default null)
returns text language plpgsql security definer set search_path to 'public' as $$
declare
  v_now_bkk date := (now() at time zone 'Asia/Bangkok')::date;
  v_from    date := (public.app_setting('champ_mode') ->> 'weekly_count_from')::date;
  v_week    date := public._bkk_week_start(now());
begin
  if p_member is null or coalesce(p_delta, 0) = 0 then return 'noop'; end if;
  if v_from is null or v_now_bkk < v_from then return 'legacy'; end if;

  -- engagement on a post from an earlier week -> lifetime bonus only, never the ranking
  if p_post_created_at is not null and public._bkk_week_start(p_post_created_at) <> v_week then
    update public.members set cookie_bonus_total = coalesce(cookie_bonus_total, 0) + p_delta
      where lower(name) = lower(p_member);
    return 'bonus';
  end if;

  insert into public.ranking_weekly (member_name, week_start, cookies)
    values (p_member, v_week, p_delta)
    on conflict (member_name, week_start) do update set cookies = ranking_weekly.cookies + excluded.cookies;

  -- monthly kept for statistics only
  perform public.bump_ranking_monthly(p_member, to_char(v_now_bkk, 'YYYY-MM'), p_delta);

  -- TODO (section E): add to the member's running Birthday Campaign total here
  return 'week';
end;
$$;
revoke execute on function public._credit_member_cookies(text, numeric, timestamptz) from anon, authenticated;

-- ---------------------------------------------------------------------
-- 4. Champ of the Week
-- ---------------------------------------------------------------------
create table if not exists public.champ_of_the_week (
  id                  bigserial primary key,
  week_start          date not null unique,
  week_end            date not null,
  name                text not null,
  group_name          text,
  total_cookie        numeric not null,
  message             text,
  post_image          text,
  post_image_fallback text,
  post_id             text,
  created_at          timestamptz not null default now()
);
alter table public.champ_of_the_week enable row level security;
grant select, insert, update, delete on public.champ_of_the_week to service_role;
grant usage, select on sequence public.champ_of_the_week_id_seq to service_role;

create or replace function public.auto_record_champ_of_the_week(p_week_start date default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_today   date := (now() at time zone 'Asia/Bangkok')::date;
  v_start   date;
  v_name    text;
  v_cookies numeric;
  v_group   text;
begin
  if p_week_start is null then
    if extract(dow from v_today) <> 0 then
      return jsonb_build_object('status', 'skipped', 'message', 'ยังไม่ถึงวันอาทิตย์ (Asia/Bangkok)');
    end if;
    v_start := v_today - 7;                 -- the week that just ended (Sun..Sat)
  else
    v_start := p_week_start;
  end if;

  if exists (select 1 from public.champ_of_the_week where week_start = v_start) then
    return jsonb_build_object('status', 'skipped', 'message', 'มีการบันทึกแชมป์ของสัปดาห์นี้แล้ว', 'weekStart', v_start);
  end if;

  select r.member_name, r.cookies, m.group_name into v_name, v_cookies, v_group
  from public.ranking_weekly r
  left join public.members m on lower(m.name) = lower(r.member_name)
  where r.week_start = v_start and r.cookies > 0
  order by r.cookies desc, r.member_name asc
  limit 1;

  if v_name is null then
    return jsonb_build_object('status', 'skipped', 'message', 'ไม่มีข้อมูลคุกกี้ของสัปดาห์นี้', 'weekStart', v_start);
  end if;

  insert into public.champ_of_the_week (week_start, week_end, name, group_name, total_cookie)
  values (v_start, v_start + 6, v_name, coalesce(v_group, 'BLM48'), v_cookies);

  -- TODO when building: broadcast notification from "BLM48" (same helper the monthly flow uses)

  return jsonb_build_object('status', 'success', 'weekStart', v_start, 'name', v_name, 'totalCookie', v_cookies);
end;
$$;

create or replace function public.get_champ_of_the_week()
returns jsonb language sql security definer set search_path to 'public' as $$
  select jsonb_build_object('status', 'success', 'data', coalesce(jsonb_agg(jsonb_build_object(
    'id', c.id,
    'weekStart', c.week_start,
    'weekEnd', c.week_end,
    'weekLabel', case when to_char(c.week_start, 'Mon') = to_char(c.week_end, 'Mon')
                      then to_char(c.week_start, 'FMDD') || '–' || to_char(c.week_end, 'FMDD Mon YYYY')
                      else to_char(c.week_start, 'FMDD Mon') || ' – ' || to_char(c.week_end, 'FMDD Mon YYYY') end,
    'name', c.name,
    'totalCookie', c.total_cookie,
    'message', c.message,
    'postImage', coalesce(c.post_image, c.post_image_fallback),
    'postId', c.post_id,
    'profileImage', m.profile_img,
    'groupName', coalesce(m.group_name, c.group_name),
    'status', case when m.member_id is null then 'Not in System' else coalesce(m.status, '') end
  ) order by c.week_start desc, c.id desc), '[]'::jsonb))
  from public.champ_of_the_week c
  left join public.members m on lower(m.name) = lower(c.name);
$$;

-- current champ mode decided server-side (never trust the device clock)
create or replace function public.get_champ_mode()
returns text language sql stable security definer set search_path to 'public' as $$
  select case
    when today >= (cfg ->> 'week_only_from')::date  then 'week'
    when today >= (cfg ->> 'transition_from')::date then 'transition'
    else 'month' end
  from (select (now() at time zone 'Asia/Bangkok')::date as today,
               public.app_setting('champ_mode') as cfg) x;
$$;

grant execute on function public.get_champ_of_the_week() to anon, authenticated, service_role;
grant execute on function public.get_champ_mode() to anon, authenticated, service_role;
revoke execute on function public.auto_record_champ_of_the_week(date) from anon, authenticated;

-- Sunday 00:10 Asia/Bangkok = Saturday 17:10 UTC
-- select cron.schedule('auto-champ-of-the-week', '10 17 * * 6', 'select public.auto_record_champ_of_the_week();');

-- ---------------------------------------------------------------------
-- 5. Group singles → app theme of the winning champ's group
-- ---------------------------------------------------------------------
create table if not exists public.group_singles (
  id            bigserial primary key,
  group_name    text not null check (group_name in ('BLM48', 'NPT48')),
  single_name   text not null,
  primary_color text not null,
  light_color   text not null,
  meta_color    text not null,
  theme         jsonb not null default '{}'::jsonb,   -- extra colours / artwork urls
  cover_url     text,
  active_from   date,
  is_current    boolean not null default false,
  created_at    timestamptz not null default now()
);
create unique index if not exists group_singles_one_current on public.group_singles (group_name) where is_current;
alter table public.group_singles enable row level security;
grant select, insert, update, delete on public.group_singles to service_role;
grant usage, select on sequence public.group_singles_id_seq to service_role;

-- ---------------------------------------------------------------------
-- 6. Admin audit log
-- ---------------------------------------------------------------------
create table if not exists public.admin_audit_log (
  id           bigserial primary key,
  admin_user   text not null,
  action       text not null,          -- e.g. 'delete_post', 'topup_token', 'delete_vote_event'
  target_table text,
  target_id    text,
  before_data  jsonb,
  detail       jsonb,
  created_at   timestamptz not null default now()
);
create index if not exists admin_audit_log_time_idx on public.admin_audit_log (created_at desc);
alter table public.admin_audit_log enable row level security;
grant select, insert on public.admin_audit_log to service_role;
grant usage, select on sequence public.admin_audit_log_id_seq to service_role;

create or replace function public._admin_log(p_admin text, p_action text, p_table text, p_id text,
                                             p_before jsonb default null, p_detail jsonb default null)
returns void language sql security definer set search_path to 'public' as $$
  insert into public.admin_audit_log (admin_user, action, target_table, target_id, before_data, detail)
  values (p_admin, p_action, p_table, p_id, p_before, p_detail);
$$;
revoke execute on function public._admin_log(text,text,text,text,jsonb,jsonb) from anon, authenticated;

-- get_fan_boards: cache 60 วินาที (2026-11-24)
-- เดิมทุกครั้งที่เปิดหน้า จะรวมยอด fan_logs + member_fan_logs ใหม่ทั้งหมด (~0.5s, อ่านดิสก์ ~14MB/ครั้ง)
-- ตอนนี้คำนวณใหม่ไม่เกินนาทีละครั้งต่อ period แบบเดียวกับ get_top_fans
-- key ของ 'today' ผูกกับวันที่ (เวลาไทย) ข้ามเที่ยงคืนแล้วจะไม่ได้ข้อมูลของเมื่อวาน

create table if not exists public.fan_boards_cache (
  key         text primary key,
  data        jsonb not null,
  computed_at timestamptz not null default now()
);
alter table public.fan_boards_cache enable row level security;
revoke all on public.fan_boards_cache from anon, authenticated;
grant all on public.fan_boards_cache to service_role;

-- ตัวคำนวณเดิม ย้ายมาเป็น _compute_fan_boards (เนื้อหาเหมือนเดิมทุกบรรทัด)
create or replace function public._compute_fan_boards(p_period text default 'all')
returns jsonb
language sql
stable security definer
set search_path to 'public'
as $function$
  with since as (
    select case when p_period = 'today'
      then ((now() at time zone 'Asia/Bangkok')::date::timestamp at time zone 'Asia/Bangkok')
      else '-infinity'::timestamptz end as t
  ),
  src as (
    select member_name, username, amount, created_at from public._top_fans_fan_rows
    union all
    select member_name, username, amount, created_at from public._top_fans_member_rows -- บัญชีเมมเบอร์ (2026-11-07)
  ),
  agg as materialized (
    select lower(fl.member_name) as mkey, fl.username, sum(fl.amount) as total, min(coalesce(fl.created_at, '-infinity'::timestamptz)) as first_at
    from src fl, since
    where (since.t = '-infinity'::timestamptz or fl.created_at >= since.t)
      and fl.username not in (select username from public.fan_board_hidden_users)
    group by 1, 2
    having sum(fl.amount) > 0
  ),
  ranked as materialized (
    select a.*, row_number() over (partition by a.mkey order by a.total desc, a.first_at asc) as rn
    from agg a
  ),
  per_member as (
    select m.name, m.profile_img,
      coalesce((select sum(total) from agg where agg.mkey = lower(m.name)), 0) as member_total,
      coalesce((
        select jsonb_agg(jsonb_build_object('username', r.username, 'name', public.disp_name(r.username, coalesce(u.name, r.username)),
               'img', public.disp_img(r.username, u.profile_img), 'total', r.total) order by r.rn)
        from ranked r left join public.users u on u.username = r.username
        where r.mkey = lower(m.name) and r.rn <= 3
      ), '[]'::jsonb) as fans
    from public.members m
    where coalesce(m.status, 'Active') = 'Active'
      and coalesce(m.group_name, 'BLM48') = 'BLM48' -- NPT48 is vote-only for now
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'name', name, 'profile_img', profile_img, 'total', member_total, 'fans', fans
  ) order by
    case when p_period = 'today' then (jsonb_array_length(fans) = 0)::int else 0 end,
    case when p_period = 'today' then -member_total else 0 end,
    upper(name)), '[]'::jsonb)
  from per_member;
$function$;

revoke all on function public._compute_fan_boards(text) from public, anon, authenticated;
grant execute on function public._compute_fan_boards(text) to service_role;

-- get_fan_boards: อ่านจาก cache ถ้าอายุไม่เกิน 60 วิ, ไม่งั้นคนแรกที่ได้ lock คำนวณใหม่
-- คนอื่นที่มาพร้อมกันใช้ของเก่าไปก่อน (ไม่รุมคำนวณซ้ำ)
create or replace function public.get_fan_boards(p_period text default 'all')
returns jsonb
language plpgsql
volatile security definer
set search_path to 'public'
as $function$
declare
  v_period text := case when p_period = 'today' then 'today' else 'all' end;
  v_key    text := case when p_period = 'today'
                     then 'today:' || (now() at time zone 'Asia/Bangkok')::date
                     else 'all' end;
  v_data jsonb;
  v_at   timestamptz;
begin
  select data, computed_at into v_data, v_at from public.fan_boards_cache where key = v_key;
  if v_data is not null and v_at > now() - interval '60 seconds' then
    return v_data;
  end if;

  if pg_try_advisory_xact_lock(hashtext('fan_boards_cache:' || v_key)) or v_data is null then
    v_data := public._compute_fan_boards(v_period);
    insert into public.fan_boards_cache (key, data, computed_at)
    values (v_key, v_data, now())
    on conflict (key) do update set data = excluded.data, computed_at = excluded.computed_at;
    -- ล้าง key 'today' ของวันก่อน ๆ
    delete from public.fan_boards_cache where key like 'today:%' and key <> v_key;
  end if;
  return v_data;
end;
$function$;

grant execute on function public.get_fan_boards(text) to anon, authenticated, service_role;

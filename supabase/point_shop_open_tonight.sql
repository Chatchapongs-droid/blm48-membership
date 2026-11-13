-- 2026-11-13: Point Shop opens to everyone 2026-11-14 00:00 Bangkok (was 2026-12-01),
-- and every non-suspended account gets its own notification (notif_type 'pointshop', sender 48-480 "BLM48")
-- at that moment. One row per account so the notify_push_on_insert trigger also sends phone pushes.
-- Applied to Supabase as migration point_shop_open_tonight_2026_11_14.
-- Also: exchange_points' "not open yet" message no longer hard-codes the old date.
CREATE OR REPLACE FUNCTION public._point_shop_open_at()
 RETURNS timestamp with time zone
 LANGUAGE sql
 IMMUTABLE
AS $function$ select timestamptz '2026-11-14 00:00:00+07' $function$;

create table if not exists public.point_shop_open_notices (
  open_at timestamptz primary key,
  sent_at timestamptz not null default now(),
  recipients int not null
);
alter table public.point_shop_open_notices enable row level security;
grant select, insert, update, delete on public.point_shop_open_notices to service_role;

CREATE OR REPLACE FUNCTION public.notify_point_shop_open()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_open timestamptz := public._point_shop_open_at();
  v_writer text; v_avatar text; v_n int;
begin
  if now() < v_open then return; end if;
  if exists (select 1 from public.point_shop_open_notices where open_at = v_open) then return; end if;

  select name, profile_img into v_writer, v_avatar from public.users where username = '48-480';

  insert into public.notifications (writer, action, avatar, role, notif_type, recipient_username)
  select coalesce(v_writer, 'BLM48'), 'Point Shop เปิดแล้ว! นำ Points มาแลก Token และ Cookie ได้เลยค่ะ',
         v_avatar, 'Admin', 'pointshop', u.username
  from public.users u
  where coalesce(u.status, '') not ilike 'suspend%';
  get diagnostics v_n = row_count;

  insert into public.point_shop_open_notices (open_at, recipients) values (v_open, v_n);

  begin
    perform cron.unschedule('point-shop-open-notify');
  exception when others then null;
  end;
end;
$function$;
revoke all on function public.notify_point_shop_open() from public, anon, authenticated;

-- 17:00 GMT on 13 Nov = 00:00 on 14 Nov Bangkok (cron runs in GMT); the job removes itself after sending
select cron.schedule('point-shop-open-notify', '0 17 13 11 *', 'select public.notify_point_shop_open();');

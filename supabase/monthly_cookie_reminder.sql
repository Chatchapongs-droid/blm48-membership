-- 2026-11-13: on the 1st of every month (09:00 Bangkok) remind every account that can claim the
-- monthly Membership cookies (role user, not suspended, not yet claimed this month).
-- One notification per account (notif_type 'monthlycookie', sender 48-480) so phone pushes fire too.
-- Applied to Supabase as migrations monthly_cookie_reminder_2026_11_13 and
-- notifications_allow_pointshop_monthlycookie_2026_11_13.
-- NOTE: notifications.notif_type has a CHECK list — any new type must be added there first
-- (the 'pointshop' notice for the Point Shop opening would have failed without it).
alter table public.notifications drop constraint notifications_notif_type_check;
alter table public.notifications add constraint notifications_notif_type_check
  check (notif_type = any (array['post','comment','reply','mention','admin','shop','wallet','preorder','theater','trade','pointshop','monthlycookie']::text[]));

create table if not exists public.monthly_cookie_reminders (
  month_year text primary key,
  sent_at timestamptz not null default now(),
  recipients int not null
);
alter table public.monthly_cookie_reminders enable row level security;
grant select, insert, update, delete on public.monthly_cookie_reminders to service_role;

CREATE OR REPLACE FUNCTION public.remind_monthly_cookie()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_month text := upper(to_char(now() at time zone 'Asia/Bangkok', 'FMMonthYYYY'));  -- same key as claim_monthly_cookie
  v_writer text; v_avatar text; v_n int;
begin
  if exists (select 1 from public.monthly_cookie_reminders where month_year = v_month) then return 0; end if;

  select name, profile_img into v_writer, v_avatar from public.users where username = '48-480';

  insert into public.notifications (writer, action, avatar, role, notif_type, recipient_username)
  select coalesce(v_writer, 'BLM48'), 'คุกกี้ Membership ประจำเดือนพร้อมให้รับแล้ว! กดรับได้ที่หน้า Profile ค่ะ',
         v_avatar, 'Admin', 'monthlycookie', u.username
  from public.users u
  where lower(coalesce(u.role, '')) = 'user'
    and coalesce(u.status, '') not ilike 'suspend%'
    and not exists (select 1 from public.monthly_cookie_claims c
                    where c.wallet_code = public.wallet_code_of(u.username) and c.month_year = v_month);
  get diagnostics v_n = row_count;

  insert into public.monthly_cookie_reminders (month_year, recipients) values (v_month, v_n);
  return v_n;
end;
$function$;
revoke all on function public.remind_monthly_cookie() from public, anon, authenticated;

-- 02:00 GMT on the 1st = 09:00 Bangkok on the 1st
select cron.schedule('monthly-cookie-reminder', '0 2 1 * *', 'select public.remind_monthly_cookie();');

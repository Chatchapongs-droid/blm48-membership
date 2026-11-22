-- 2026-11-22 Auto daily check-in + Daily Mission reward for chosen accounts (00-35, 00-7)
-- Cron 'auto-daily-accounts' runs 23:50 Asia/Bangkok (16:50 UTC): record_daily_login (today's check-in,
-- also pays any fully checked-in past month 100 Token) + today's Daily Mission reward (10 Token) if not claimed.
-- Add/remove accounts: insert/delete rows in public.auto_daily_accounts.
create table if not exists public.auto_daily_accounts (
  username text primary key references public.users(username) on update cascade on delete cascade,
  added_at timestamptz not null default now()
);
alter table public.auto_daily_accounts enable row level security;
revoke all on public.auto_daily_accounts from anon, authenticated;
grant all on public.auto_daily_accounts to service_role;

create or replace function public._auto_daily_complete(p_username text, p_date date)
returns numeric language plpgsql security definer set search_path to 'public' as $$
declare n int;
begin
  insert into public.login_checkins (username, checkin_date, source, created_at)
    values (p_username, p_date, 'login', least(now(), (p_date + time '23:50') at time zone 'Asia/Bangkok'))
    on conflict (username, checkin_date) do nothing;

  insert into public.daily_missions (username, mission_date, claimed, claimed_at, updated_at)
    values (p_username, p_date, true, now(), now())
    on conflict (username, mission_date) do update set claimed = true, claimed_at = now(), updated_at = now()
    where not public.daily_missions.claimed;
  get diagnostics n = row_count;
  if n = 0 then return 0; end if;

  update public.users set token = token + 10, updated_at = now() where username = p_username;
  insert into public.wallet_logs (wallet_code, action, target, amount)
    values (public.wallet_code_of(p_username), 'Daily Mission Reward', to_char(p_date, 'YYYY-MM-DD'), 10);
  return 10;
end $$;
revoke all on function public._auto_daily_complete(text, date) from public, anon, authenticated;

create or replace function public.run_auto_daily_accounts()
returns void language plpgsql security definer set search_path to 'public' as $$
declare r record; v_today date := (now() at time zone 'Asia/Bangkok')::date;
begin
  for r in select username from public.auto_daily_accounts loop
    perform public.record_daily_login(r.username);
    perform public._auto_daily_complete(r.username, v_today);
  end loop;
end $$;
revoke all on function public.run_auto_daily_accounts() from public, anon, authenticated;

select cron.schedule('auto-daily-accounts', '50 16 * * *', $$select public.run_auto_daily_accounts();$$);

insert into public.auto_daily_accounts (username) values ('00-35'), ('00-7') on conflict do nothing;

-- One-time backfill run on 2026-11-22 (not re-runnable as-is): every unclaimed mission day from
-- 2026-09-02 (00-35, first activity) / 2026-08-05 (00-7, mission launch) to today at 10 Token/day,
-- missing check-ins filled from 2026-09-01, then record_daily_login paid 00-7's September (+100).
-- Result: 00-35 +710 Token, 00-7 +950 Token, one "BLM48" wallet notification each.

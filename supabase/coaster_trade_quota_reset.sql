-- 🔁 Coaster Trade daily quota reset (2026-11-08, migration coaster_trade_quota_reset)
-- Admin can give an account its 3 trades back for today without deleting any trade history:
-- insert a row here; _coaster_trade_status counts today's trades only from
-- greatest(Bangkok midnight, latest reset_at for that wallet).
-- First use: Emmy (00-108, wallet 5094654123) tests the system — reset on request 2026-11-08.
--
--   insert into public.coaster_trade_quota_resets (wallet_code, note) values ('<wallet_code>', '<why>');

create table if not exists public.coaster_trade_quota_resets (
  id bigint generated always as identity primary key,
  wallet_code text not null,
  reset_at timestamptz not null default now(),
  note text
);
create index if not exists coaster_trade_quota_resets_wc_idx on public.coaster_trade_quota_resets (wallet_code, reset_at desc);
alter table public.coaster_trade_quota_resets enable row level security;
grant select, insert, update, delete on public.coaster_trade_quota_resets to service_role;

create or replace function public._coaster_trade_status(p_username text) returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare
  v_wc text := public.wallet_code_of(p_username);
  v_created timestamptz;
  v_status text;
  v_today date := (now() at time zone 'Asia/Bangkok')::date;
  v_from timestamptz;
  v_used int;
  v_open int;
  v_offers int;
  v_reason text;
begin
  select status into v_status from public.users where username = p_username;
  select created_at into v_created from public.user_wallets where username = p_username;
  -- today's count starts at Bangkok midnight, or at the latest admin quota reset if that is later
  v_from := greatest((v_today::timestamp at time zone 'Asia/Bangkok'),
                     coalesce((select max(reset_at) from public.coaster_trade_quota_resets where wallet_code = v_wc), '-infinity'::timestamptz));
  select (select count(*) from public.coaster_trades t
           where t.owner_wallet = v_wc and t.status <> 'cancelled' and t.created_at >= v_from)
       + (select count(*) from public.coaster_trade_offers o
           where o.offerer_wallet = v_wc and o.status in ('pending','accepted') and o.created_at >= v_from)
       + (select count(*) from public.coaster_trades t
           where t.taker_wallet = v_wc and t.done_at >= v_from
             and not exists (select 1 from public.coaster_trade_offers o where o.trade_id = t.id and o.status = 'accepted'))
    into v_used;
  select count(*) into v_open from public.coaster_trades where owner_wallet = v_wc and status = 'open';
  select count(*) into v_offers from public.coaster_trade_offers where offerer_wallet = v_wc and status = 'pending';
  if v_wc is null or v_status is null then v_reason := 'Account not found';
  elsif v_status <> 'active' then v_reason := 'This account cannot use trading';
  elsif v_created is null or v_created > now() - interval '14 days' then
    v_reason := 'Trading unlocks when your account is 14 days old (' ||
      to_char((coalesce(v_created, now()) + interval '14 days') at time zone 'Asia/Bangkok', 'DD/MM/YYYY') || ')';
  end if;
  return jsonb_build_object('walletCode', v_wc, 'eligible', v_reason is null, 'reason', v_reason,
    'usedToday', v_used, 'dailyLimit', 3, 'openCount', v_open, 'maxOpen', 5, 'pendingOffers', v_offers, 'maxOffers', 5);
end;
$$;
revoke execute on function public._coaster_trade_status(text) from public, anon, authenticated;

insert into public.coaster_trade_quota_resets (wallet_code, note)
values ('5094654123', 'Emmy (00-108) tests the trade system — reset requested by admin 2026-11-08');

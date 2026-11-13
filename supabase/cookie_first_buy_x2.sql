-- 2026-11-13: first purchase of each cookie pack gives x2 Cookies (once per account per pack).
-- Applied to Supabase as migration cookie_first_buy_x2_2026_11_13.
-- Counts from launch only: purchases before 2026-11-13 do not use up the x2.
-- exchange_cookies() (see cookie_pack_ladder.sql for the price ladder) now also:
--   insert into cookie_pack_first_buys ... on conflict do nothing; if inserted -> reward x2,
--   returns 'cookies' (actual amount) and 'firstBuyBonus' (bool).
create table if not exists public.cookie_pack_first_buys (
  wallet_code text not null references public.user_wallets(wallet_code) on update cascade,
  token_price numeric not null,
  cookies numeric not null,
  bought_at timestamptz not null default now(),
  primary key (wallet_code, token_price)
);
alter table public.cookie_pack_first_buys enable row level security;
grant select, insert, update, delete on public.cookie_pack_first_buys to service_role;

CREATE OR REPLACE FUNCTION public.get_cookie_first_buys(p_username text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select jsonb_build_object('status', 'success', 'used',
    coalesce((select jsonb_agg(token_price order by token_price) from public.cookie_pack_first_buys
              where wallet_code = public.wallet_code_of(p_username)), '[]'::jsonb));
$function$;
grant execute on function public.get_cookie_first_buys(text) to anon, authenticated;

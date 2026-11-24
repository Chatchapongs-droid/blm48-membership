-- GE Token หมดอายุ 31/12/2026: เหรียญ GE Token ทุกเหรียญในระบบถูก burn เมื่อ 01/01/2027 00:00 (เวลาไทย)
-- Applied to rqhwzbrcgnpxtuaeoxml on 2026-11-24 (migration ge_token_year_end_burn_2026).
-- Cancel before it runs:  select cron.unschedule('ge-token-burn-2026');
create table if not exists public.ge_token_burns (
  burn_key   text primary key,
  burned_at  timestamptz not null default now(),
  holders    integer not null,
  total      numeric not null
);
alter table public.ge_token_burns enable row level security;
revoke all on public.ge_token_burns from anon, authenticated;
grant all on public.ge_token_burns to service_role;

create or replace function public.burn_expired_ge_tokens(p_burn_key text default '2026')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_holders integer;
  v_total   numeric;
begin
  -- กันรันซ้ำ
  if exists (select 1 from ge_token_burns where burn_key = p_burn_key) then
    return jsonb_build_object('ok', false, 'message', 'already burned', 'burn_key', p_burn_key);
  end if;

  -- ลงประวัติในกระเป๋าของแต่ละคนก่อนล้างยอด
  insert into wallet_logs (created_at, action, target, amount, wallet_code)
  select now(), 'GE Token หมดอายุ', 'Burn (End date 31/12/' || p_burn_key || ') - GE Token', -u.ge_token, w.wallet_code
  from users u
  left join user_wallets w on w.username = u.username
  where coalesce(u.ge_token, 0) > 0;

  select count(*), coalesce(sum(ge_token), 0) into v_holders, v_total
  from users where coalesce(ge_token, 0) > 0;

  update users set ge_token = 0 where coalesce(ge_token, 0) <> 0;

  insert into ge_token_burns (burn_key, holders, total) values (p_burn_key, v_holders, v_total);

  return jsonb_build_object('ok', true, 'burn_key', p_burn_key, 'holders', v_holders, 'total', v_total);
end;
$$;
revoke all on function public.burn_expired_ge_tokens(text) from public, anon, authenticated;
grant execute on function public.burn_expired_ge_tokens(text) to service_role;

-- 31 Dec 17:00 UTC = 1 Jan 00:00 Asia/Bangkok. Function is guarded, so later years are no-ops.
select cron.schedule('ge-token-burn-2026', '0 17 31 12 *', $$select public.burn_expired_ge_tokens('2026');$$);

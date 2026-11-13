-- 2026-11-13: Top Up Cookies 8-pack ladder (1 Token = 10 Cookies + bonus per pack, max +30%).
-- Applied to Supabase as migration cookie_pack_ladder_2026_11_13.
-- Reward is decided here from the Token price; prices not on the ladder are rejected.
-- Keep in sync with COOKIE_PACKS in topup_cookies.html.
CREATE OR REPLACE FUNCTION public.exchange_cookies(p_username text, p_token_price numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_user record;
  v_reward numeric;
  v_new_token numeric;
  v_new_cookie numeric;
begin
  if p_username is null or p_token_price is null or p_token_price <= 0 then
    return jsonb_build_object('status', 'error', 'message', 'Invalid request.');
  end if;

  v_reward := case p_token_price
    when 10   then 100
    when 50   then 525
    when 100  then 1100
    when 250  then 2875
    when 400  then 4800
    when 1000 then 12500
    when 2500 then 32500
    when 5000 then 65000
    else null end;
  if v_reward is null then
    return jsonb_build_object('status', 'error', 'message', 'This pack is not available.');
  end if;

  select * into v_user from public.users where username = p_username for update;
  if not found then
    return jsonb_build_object('status', 'error', 'message', 'User not found.');
  end if;

  if v_user.token < p_token_price then
    return jsonb_build_object('status', 'error', 'message', 'Not enough Tokens.');
  end if;

  v_new_token := v_user.token - p_token_price;
  v_new_cookie := v_user.cookie + v_reward;

  update public.users set token = v_new_token, cookie = v_new_cookie, updated_at = now() where username = p_username;
  insert into public.wallet_logs (wallet_code, action, target, amount) values (public.wallet_code_of(p_username), 'แลกซื้อคุกกี้', '-' || p_token_price, v_reward);

  return jsonb_build_object('status', 'success', 'message', 'OK', 'newToken', v_new_token, 'newCookie', v_new_cookie, 'cookies', v_reward);
end;
$function$;

-- 2026-11-13: members get their own Point Shop prices: 200 Member Score = 1 Token base
-- (fans/admins stay at 500 Fan Score = 1 Token, see point_shop_prices_x5.sql). Same ids, amounts and bonuses.
-- Applied to Supabase as migration point_shop_member_prices_2026_11_13.
-- get_point_shop and exchange_points now call _point_shop_packages_for(p_username) instead of
-- _point_shop_packages() (done in the migration by text replace on their current definitions).
CREATE OR REPLACE FUNCTION public._point_shop_packages_for(p_username text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select case
    when exists (select 1 from public.users u where u.username = p_username and lower(u.role) = 'member') then '[
      {"id":"t100",   "kind":"token",  "points":200,    "amount":1,    "bonus":0},
      {"id":"t1000",  "kind":"token",  "points":2000,   "amount":11,   "bonus":10},
      {"id":"t5000",  "kind":"token",  "points":10000,  "amount":60,   "bonus":20},
      {"id":"t10000", "kind":"token",  "points":20000,  "amount":130,  "bonus":30},
      {"id":"c100",   "kind":"cookie", "points":200,    "amount":10,   "bonus":0},
      {"id":"c1000",  "kind":"cookie", "points":2000,   "amount":110,  "bonus":10},
      {"id":"c5000",  "kind":"cookie", "points":10000,  "amount":600,  "bonus":20},
      {"id":"c10000", "kind":"cookie", "points":20000,  "amount":1300, "bonus":30}
    ]'::jsonb
    else public._point_shop_packages() end;
$function$;
revoke all on function public._point_shop_packages_for(text) from public, anon, authenticated;

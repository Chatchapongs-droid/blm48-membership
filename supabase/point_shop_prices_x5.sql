-- 2026-11-13: CEO request - Points are easy to earn (about half come free from likes/comments),
-- so exchanging costs 5x more: 500 Points = 1 Token base (was 100). Amounts and bonuses unchanged.
-- Applied to Supabase as migration point_shop_prices_x5_2026_11_13.
-- Used by exchange_points() and get_point_shop(); point_shop.html derives the pre-bonus amount from bonus %.
CREATE OR REPLACE FUNCTION public._point_shop_packages()
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select '[
    {"id":"t100",   "kind":"token",  "points":500,    "amount":1,    "bonus":0},
    {"id":"t1000",  "kind":"token",  "points":5000,   "amount":11,   "bonus":10},
    {"id":"t5000",  "kind":"token",  "points":25000,  "amount":60,   "bonus":20},
    {"id":"t10000", "kind":"token",  "points":50000,  "amount":130,  "bonus":30},
    {"id":"c100",   "kind":"cookie", "points":500,    "amount":10,   "bonus":0},
    {"id":"c1000",  "kind":"cookie", "points":5000,   "amount":110,  "bonus":10},
    {"id":"c5000",  "kind":"cookie", "points":25000,  "amount":600,  "bonus":20},
    {"id":"c10000", "kind":"cookie", "points":50000,  "amount":1300, "bonus":30}
  ]'::jsonb;
$function$;

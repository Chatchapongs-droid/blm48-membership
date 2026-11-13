-- 2026-11-13: small cookie pack for fans so a typical fan (~95 Points/month) has something to
-- exchange sooner: 250 Points -> 5 Cookies (same 500 P = 10 Cookies rate, no bonus).
-- Applied to Supabase as migration point_shop_fan_mini_cookie_pack_2026_11_13.
-- Supersedes the fan table in point_shop_prices_x5.sql. Members keep _point_shop_packages_for().
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
    {"id":"c250",   "kind":"cookie", "points":250,    "amount":5,    "bonus":0},
    {"id":"c100",   "kind":"cookie", "points":500,    "amount":10,   "bonus":0},
    {"id":"c1000",  "kind":"cookie", "points":5000,   "amount":110,  "bonus":10},
    {"id":"c5000",  "kind":"cookie", "points":25000,  "amount":600,  "bonus":20},
    {"id":"c10000", "kind":"cookie", "points":50000,  "amount":1300, "bonus":30}
  ]'::jsonb;
$function$;

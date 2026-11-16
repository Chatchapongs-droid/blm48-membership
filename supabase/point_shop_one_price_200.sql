-- 2026-11-16: one Point Shop price for every role: 200 P = 1 Token (= 10 Cookie).
-- Emmy: fans should get the same rate as members (free fan Points are now capped 30/day).
-- Fan mini pack c250 dropped (the 200 P pack is cheaper).
CREATE OR REPLACE FUNCTION public._point_shop_packages()
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select '[
    {"id":"t100",   "kind":"token",  "points":200,    "amount":1,    "bonus":0},
    {"id":"t1000",  "kind":"token",  "points":2000,   "amount":11,   "bonus":10},
    {"id":"t5000",  "kind":"token",  "points":10000,  "amount":60,   "bonus":20},
    {"id":"t10000", "kind":"token",  "points":20000,  "amount":130,  "bonus":30},
    {"id":"c100",   "kind":"cookie", "points":200,    "amount":10,   "bonus":0},
    {"id":"c1000",  "kind":"cookie", "points":2000,   "amount":110,  "bonus":10},
    {"id":"c5000",  "kind":"cookie", "points":10000,  "amount":600,  "bonus":20},
    {"id":"c10000", "kind":"cookie", "points":20000,  "amount":1300, "bonus":30}
  ]'::jsonb;
$function$;

CREATE OR REPLACE FUNCTION public._point_shop_packages_for(p_username text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select public._point_shop_packages();
$function$;

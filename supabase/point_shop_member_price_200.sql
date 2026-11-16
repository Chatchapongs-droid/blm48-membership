-- 2026-11-16: member Point Shop prices 5x cheaper: 200 P = 1 Token (= 10 Cookie).
-- Emmy: member points come from likes/gifts, 1,000 P = 1 Token felt not worth it.
-- Fans/admins keep _point_shop_packages() (500 P = 1 Token).
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

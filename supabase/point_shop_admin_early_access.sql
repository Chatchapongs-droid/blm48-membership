-- 2026-11-13: Point Shop opens to Admin/CEO accounts (is_admin_or_ceo: role admin/ceo or users.is_admin)
-- right away; everyone else still waits for _point_shop_open_at() (2026-12-01 00:00 Bangkok).
-- Applied to Supabase as migration point_shop_admin_early_access_2026_11_13.
-- get_point_shop: isOpen = opened OR admin; adds adminPreview (true only for admins before opening).
-- exchange_points: the opening check became
--   if now() < public._point_shop_open_at() and not public.is_admin_or_ceo(p_username) then ... refuse
-- Admin exchanges are real (Points deducted, Token/Cookie credited).
CREATE OR REPLACE FUNCTION public.get_point_shop(p_username text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select case when b.score_kind is null then jsonb_build_object('status', 'fail', 'message', 'ไม่พบบัญชีผู้ใช้ค่ะ')
  else jsonb_build_object(
    'status', 'success',
    'openAt', public._point_shop_open_at(),
    'isOpen', now() >= public._point_shop_open_at() or public.is_admin_or_ceo(p_username),
    'adminPreview', now() < public._point_shop_open_at() and public.is_admin_or_ceo(p_username),
    'scoreKind', b.score_kind,
    'points', b.points,
    'tier', case when b.score_kind = 'fan' then (select t.tier from public._fan_score_tier(p_username) t) end,
    'packages', public._point_shop_packages(),
    'recent', coalesce((select jsonb_agg(jsonb_build_object('points', x.points, 'kind', x.reward_kind, 'amount', x.reward_amount, 'at', x.created_at) order by x.created_at desc)
                          from (select * from public.point_exchanges where username = p_username order by created_at desc limit 5) x), '[]'::jsonb)
  ) end
  from (select 1) one left join public._point_balance(p_username) b on true;
$function$;

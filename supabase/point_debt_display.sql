-- 2026-11-23: show a negative Points balance instead of a silent 0.
-- A member who exchanges all her Points and then loses likes/cookies ends up below 0
-- (member_score_rows().total is floored at 0, so the page showed 0 and new Points looked
-- like they "didn't come in" while they were paying the deficit). Both RPCs now return
-- `debt` (>= 0): the Points still owed before the balance goes up again.

create or replace function public._point_debt(p_username text)
returns numeric
language sql stable security definer set search_path to 'public'
as $function$
  select case when lower(u.role) = 'member' then
           coalesce((select greatest(0, -(r.cookie_pts + r.like_pts + r.post_pts + r.comment_pts
                     - coalesce((select sum(x.points) from public.point_exchanges x
                                  where x.username = r.username and x.score_kind = 'member'), 0)))
                     from public.member_score_rows() r where r.username = u.username limit 1), 0)
         else greatest(0, -coalesce(u.fan_cookies, 0)) end
  from public.users u where u.username = p_username;
$function$;
revoke all on function public._point_debt(text) from public, anon, authenticated;

create or replace function public.get_member_score(p_username text)
returns jsonb
language sql stable security definer set search_path to 'public'
as $function$
  select jsonb_build_object(
    'name', name, 'cookies', cookies, 'likes', likes, 'posts', posts, 'comments', comments,
    'cookie_pts', cookie_pts, 'like_pts', like_pts, 'post_pts', post_pts, 'comment_pts', comment_pts,
    'total', total,
    'debt', coalesce(public._point_debt(p_username), 0))
  from public.member_score_rows()
  where username = p_username
  limit 1;
$function$;

create or replace function public.get_point_shop(p_username text)
returns jsonb
language sql stable security definer set search_path to 'public'
as $function$
  select case when b.score_kind is null then jsonb_build_object('status', 'fail', 'message', 'ไม่พบบัญชีผู้ใช้ค่ะ')
  else jsonb_build_object(
    'status', 'success',
    'openAt', public._point_shop_open_at(),
    'isOpen', now() >= public._point_shop_open_at() or public.is_admin_or_ceo(p_username),
    'adminPreview', now() < public._point_shop_open_at() and public.is_admin_or_ceo(p_username),
    'scoreKind', b.score_kind,
    'points', greatest(0, b.points),
    'debt', coalesce(public._point_debt(p_username), 0),
    'tier', case when b.score_kind = 'fan' then (select t.tier from public._fan_score_tier(p_username) t) end,
    'packages', public._point_shop_packages_for(p_username),
    'recent', coalesce((select jsonb_agg(jsonb_build_object('points', x.points, 'kind', x.reward_kind, 'amount', x.reward_amount, 'at', x.created_at) order by x.created_at desc)
                          from (select * from public.point_exchanges where username = p_username order by created_at desc limit 5) x), '[]'::jsonb)
  ) end
  from (select 1) one left join public._point_balance(p_username) b on true;
$function$;

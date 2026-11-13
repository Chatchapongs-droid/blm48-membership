-- 2026-11-13: Point Shop exchange history page (point_shop_history.html).
-- Applied to Supabase as migration point_shop_history_2026_11_13.
-- Returns the caller's own exchanges, newest first, paged by created_at cursor (p_before),
-- plus lifetime totals (Points used, Tokens and Cookies received).
CREATE OR REPLACE FUNCTION public.get_point_exchange_history(p_username text, p_before timestamptz DEFAULT NULL, p_limit integer DEFAULT 30)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select jsonb_build_object(
    'status', 'success',
    'totals', (select jsonb_build_object(
                 'count', count(*),
                 'points', coalesce(sum(e.points), 0),
                 'tokens', coalesce(sum(e.reward_amount) filter (where e.reward_kind = 'token'), 0),
                 'cookies', coalesce(sum(e.reward_amount) filter (where e.reward_kind = 'cookie'), 0))
               from public.point_exchanges e where e.username = p_username),
    'items', coalesce((select jsonb_agg(jsonb_build_object('points', x.points, 'kind', x.reward_kind, 'amount', x.reward_amount, 'at', x.created_at) order by x.created_at desc)
                       from (select * from public.point_exchanges e
                             where e.username = p_username and (p_before is null or e.created_at < p_before)
                             order by e.created_at desc
                             limit least(greatest(coalesce(p_limit, 30), 1), 100)) x), '[]'::jsonb)
  );
$function$;

GRANT EXECUTE ON FUNCTION public.get_point_exchange_history(text, timestamptz, integer) TO anon, authenticated;

-- 2026-11-26: Pre-order Collection order totals
--  * admin_list_collections: each collection gets isPreorder + preorder {orders, buyers, draws, cards, tokens, waitingDraws, shippedAt}
--  * admin_get_sales_summary: new 'preorderCollections' card (all pre-order Collection orders, paid at checkout,
--    shipped or not). Those collections are left out of the 'gacha' card so they are not counted twice once
--    shipping writes their cards to sales_log (one row per card, which would also multiply by cards_per_draw).
-- Source: shop_order_items kind='gacha' and is_preorder; draws = variant (1|5) x quantity, Token = line_total.

-- per-collection pre-order totals
create or replace function public._collection_preorder_stats(p_collection_id text)
returns jsonb language sql stable security definer set search_path to 'public' as $$
  select jsonb_build_object(
    'orders', count(*),
    'buyers', count(distinct o.wallet_code),
    'draws', coalesce(sum(oi.variant * oi.quantity), 0),
    'cards', coalesce(sum(oi.variant * oi.quantity), 0)
             * greatest(coalesce((select cards_per_draw from public.collections where collection_id = p_collection_id), 1), 1),
    'tokens', coalesce(sum(oi.line_total), 0),
    'waitingDraws', coalesce(sum(oi.pending_draws) filter (where oi.status = 'waiting'), 0),
    -- 2026-11-26: GE Token bonus (preorder_bonus.geToken = line total). issued = already credited, pending = timing 'ship' not yet credited
    'geIssued', coalesce(sum((oi.preorder_bonus->>'geToken')::numeric) filter (where coalesce((oi.preorder_bonus->>'credited')::boolean, false)), 0),
    'gePending', coalesce(sum((oi.preorder_bonus->>'geToken')::numeric) filter (where not coalesce((oi.preorder_bonus->>'credited')::boolean, false)), 0)
  )
  from public.shop_order_items oi
  join public.shop_orders o on o.id = oi.order_id
  where oi.kind = 'gacha' and oi.is_preorder and oi.ref_id = p_collection_id;
$$;
revoke all on function public._collection_preorder_stats(text) from public, anon, authenticated;

create or replace function public.admin_list_collections(p_admin_username text)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
begin
  if not public.is_admin_or_ceo(p_admin_username) then
    return jsonb_build_object('status','error','message','You do not have permission to do this');
  end if;
  return jsonb_build_object('status','success','data', coalesce((
    select jsonb_agg(jsonb_build_object(
      'collectionId', c.collection_id, 'name', c.collection_name, 'coverImage', c.cover_image,
      'category', c.category, 'group', c.group_name, 'state', public._admin_collection_state(c),
      'costTokens', c.cost_tokens, 'costTokensX5', c.cost_tokens_x5, 'allowX5', coalesce(c.allow_x5, true), 'cardsPerDraw', coalesce(c.cards_per_draw, 1),
      'saleStartAt', c.sale_start_at, 'saleEndAt', c.sale_end_at,
      'isLucky', c.draw_mode = 'lucky',
      'itemCount', it.n, 'ssrCount', it.ssr, 'stock', it.stock, 'ssrStock', it.ssr_stock,  -- 2026-11-26: Normal stock = stock - ssrStock
      'sold', (select count(*) from public.sales_log s where s.kind = 'gacha' and s.collection_id = c.collection_id),
      'isPreorder', coalesce(c.is_preorder, false),
      'preorder', case when coalesce(c.is_preorder, false)
                         or exists (select 1 from public.shop_order_items x where x.kind = 'gacha' and x.is_preorder and x.ref_id = c.collection_id)
                       then public._collection_preorder_stats(c.collection_id) || jsonb_build_object('shippedAt', c.preorder_shipped_at)
                  end,
      'updatedAt', c.updated_at
    ) order by coalesce(c.sale_start_at, c.updated_at) desc nulls last)
    from public.collections c
    cross join lateral (
      select count(*) n, count(*) filter (where i.tag = 'SSR') ssr, coalesce(sum(i.stock), 0) stock,
             coalesce(sum(i.stock) filter (where i.tag = 'SSR'), 0) ssr_stock
      from public.items i where i.collection_id = c.collection_id
    ) it
    where c.collection_id like 'gacha\_%'
  ), '[]'::jsonb));
end; $function$;

-- Sales Summary: patch in place by anchor (same style as collection_preorder.sql)
do $$
declare v_def text; v_new text;
begin
  v_def := pg_get_functiondef('public.admin_get_sales_summary(text)'::regprocedure);
  if v_def like '%preorderCollections%' then return; end if;
  v_new := v_def;

  v_new := replace(v_new, $a$  v_preorder_totals jsonb;$a$, $b$  v_preorder_totals jsonb;
  v_pc jsonb;
  v_pc_totals jsonb;$b$);

  -- gacha card: leave out pre-order collections (counted in their own card)
  v_new := replace(v_new, $a$from public.sales_log where kind = 'gacha'
      group by collection_id$a$, $b$from public.sales_log where kind = 'gacha'
        and collection_id not in (select ref_id from public.shop_order_items where kind = 'gacha' and is_preorder)
      group by collection_id$b$);

  v_new := replace(v_new, $a$  -- Gift Shop: actual Cookie purchases$a$, $b$  -- Pre-order Collections: every checkout line counts (Token paid at checkout), shipped or still waiting
  select coalesce(jsonb_agg(jsonb_build_object(
      'collectionId', c.collection_id, 'name', coalesce(c.collection_name, s.ref_id), 'coverImage', c.cover_image,
      'shipped', c.preorder_shipped_at is not null and s.waiting = 0,
      'orders', s.orders, 'buyers', s.buyers, 'draws', s.draws, 'waitingDraws', s.waiting,
      'tokenRevenue', s.revenue
    ) order by s.revenue desc), '[]'::jsonb),
    jsonb_build_object('orders', coalesce(sum(s.orders), 0), 'draws', coalesce(sum(s.draws), 0), 'tokenRevenue', coalesce(sum(s.revenue), 0))
    into v_pc, v_pc_totals
    from (
      select oi.ref_id, count(*) orders, count(distinct o.wallet_code) buyers,
             sum(oi.variant * oi.quantity) draws, sum(oi.line_total) revenue,
             coalesce(sum(oi.pending_draws) filter (where oi.status = 'waiting'), 0) waiting
      from public.shop_order_items oi join public.shop_orders o on o.id = oi.order_id
      where oi.kind = 'gacha' and oi.is_preorder
      group by oi.ref_id
    ) s
    left join public.collections c on c.collection_id = s.ref_id;

  -- Gift Shop: actual Cookie purchases$b$);

  v_new := replace(v_new, $a$      'preorder', jsonb_build_object('items', v_preorder, 'totals', v_preorder_totals),$a$,
    $b$      'preorder', jsonb_build_object('items', v_preorder, 'totals', v_preorder_totals),
      'preorderCollections', jsonb_build_object('items', v_pc, 'totals', v_pc_totals),$b$);

  v_new := replace(v_new, $a$                        + coalesce((v_preorder_totals->>'tokenRevenue')::numeric, 0),$a$,
    $b$                        + coalesce((v_preorder_totals->>'tokenRevenue')::numeric, 0)
                        + coalesce((v_pc_totals->>'tokenRevenue')::numeric, 0),$b$);

  if v_new not like '%v_pc_totals->>%' or v_new not like '%not in (select ref_id%' or v_new not like '%''preorderCollections''%' then
    raise exception 'admin_get_sales_summary anchors not found';
  end if;
  execute v_new;
end $$;

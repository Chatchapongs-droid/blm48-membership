-- 2026-11-22: Pre-order collections can be capped by stock.
-- collections.preorder_limit_stock (default true): checkout reserves cards against total card stock
-- (stock - cards owed by waiting orders). When nothing is left the collection turns Sold Out.
-- Off = unlimited pre-order (cards/stock can be added later). Ship draws from cards with stock first.

alter table public.collections add column if not exists preorder_limit_stock boolean not null default true;

-- cards still free to sell = card stock - cards owed by waiting pre-order lines
create or replace function public._preorder_available(p_collection_id text)
returns integer language sql stable security definer set search_path to 'public' as $$
  select (coalesce((select sum(stock) from public.items where collection_id = p_collection_id and rate > 0), 0)
        - coalesce((select sum(pending_draws) from public.shop_order_items
                     where kind = 'gacha' and ref_id = p_collection_id and status = 'waiting' and pending_draws > 0), 0)
          * greatest(coalesce((select cards_per_draw from public.collections where collection_id = p_collection_id), 1), 1))::int;
$$;
revoke all on function public._preorder_available(text) from public, anon, authenticated;

do $$
declare v_def text; r record;
begin
  for r in select * from (values
    -- checkout reservation: refuse when stock is short; Sold Out once fewer than one draw is left
    ('_reserve_preorder_draws(text,text,integer,integer)'::regprocedure,
     $a$  if v_status = 'Closed' then return$a$,
     $b$  if v_status = 'Sold Out' then return jsonb_build_object('status','fail','message','This collection is sold out.'); end if;
  if v_status = 'Closed' then return$b$),
    ('_reserve_preorder_draws(text,text,integer,integer)'::regprocedure,
     $a$  update public.users set token = token - v_cost * p_qty, updated_at = now() where username = p_username;$a$,
     $b$  if coalesce(v_col.preorder_limit_stock, true)
     and public._preorder_available(p_collection_id) < p_pull * p_qty * greatest(coalesce(v_col.cards_per_draw, 1), 1) then
    return jsonb_build_object('status','fail','message','Not enough stock remaining for this draw.');
  end if;

  update public.users set token = token - v_cost * p_qty, updated_at = now() where username = p_username;$b$),
    ('_reserve_preorder_draws(text,text,integer,integer)'::regprocedure,
     $a$  return jsonb_build_object('status','success');$a$,
     $b$  -- pending_draws of this line are written by shop_checkout after this call, so count them here
  if coalesce(v_col.preorder_limit_stock, true)
     and public._preorder_available(p_collection_id) - p_pull * p_qty * greatest(coalesce(v_col.cards_per_draw, 1), 1)
         < greatest(coalesce(v_col.cards_per_draw, 1), 1) then
    update public.collections set status = 'Sold Out', updated_at = now() where collection_id = p_collection_id;
  end if;
  return jsonb_build_object('status','success');$b$),
    -- ship: prefer cards that still have stock
    ('_draw_preorder_cards(text,text,integer)'::regprocedure,
     $a$      v_excl := case when exists (select 1 from public.items where collection_id = p_collection_id and rate > 0 and not (id = any(v_pack)))
                     then v_pack else '{}'::bigint[] end;$a$,
     $b$      v_excl := case when exists (select 1 from public.items where collection_id = p_collection_id and rate > 0 and not (id = any(v_pack)))
                     then v_pack else '{}'::bigint[] end;
      -- cards with stock first; once none are left, any card with a rate
      v_excl := v_excl || coalesce((select array_agg(id) from public.items
                  where collection_id = p_collection_id and rate > 0 and stock <= 0
                    and exists (select 1 from public.items x where x.collection_id = p_collection_id and x.rate > 0 and x.stock > 0 and not (x.id = any(v_excl)))),
                  '{}'::bigint[]);$b$),
    -- admin: save the switch, status follows the free stock
    ('admin_save_collection(text,text,jsonb,jsonb)'::regprocedure,
     $a$      preorder_bonus_timing = v_timing,$a$,
     $b$      preorder_bonus_timing = v_timing,
      preorder_limit_stock = coalesce((v_pre->>'limitStock')::boolean, preorder_limit_stock),$b$),
    ('admin_save_collection(text,text,jsonb,jsonb)'::regprocedure,
     $a$when draw_mode = 'lucky' or v_is_pre or v_stock > 0 then 'Open'$a$,
     $b$when draw_mode = 'lucky' then 'Open'
      when v_is_pre and not coalesce((p_col->'preorder'->>'limitStock')::boolean, preorder_limit_stock) then 'Open'
      when v_is_pre then case when public._preorder_available(v_id) >= greatest(coalesce(cards_per_draw, 1), 1) then 'Open' else 'Sold Out' end
      when v_stock > 0 then 'Open'$b$),
    ('admin_get_collection(text,text)'::regprocedure,
     $a$      'shippedAt', c.preorder_shipped_at,$a$,
     $b$      'shippedAt', c.preorder_shipped_at, 'limitStock', coalesce(c.preorder_limit_stock, true),
      'available', public._preorder_available(c.collection_id),$b$)
  ) t(fn, anchor, repl) loop
    v_def := pg_get_functiondef(r.fn);
    if position(r.repl in v_def) > 0 then continue; end if;
    if position(r.anchor in v_def) = 0 then raise exception 'anchor not found in %: %', r.fn, left(r.anchor, 80); end if;
    execute replace(v_def, r.anchor, r.repl);
  end loop;
end $$;

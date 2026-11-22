-- 2026-11-22: Pre-order Collections can be sold before their cards/stock exist.
-- Checkout charges Token + gives the bonus, but the card draw is deferred: shop_order_items.pending_draws
-- holds how many draws are owed. admin_ship_collection_preorder draws them (by rate, ignoring stock),
-- writes sales_log, fills rewards, then marks the lines ready.

alter table public.shop_order_items add column if not exists pending_draws integer not null default 0;

-- Draws owed by one wallet on one collection (already drawn + still pending)
create or replace function public._collection_draws_used(p_wallet text, p_collection_id text)
returns integer language sql stable security definer set search_path to 'public' as $$
  select (
    (select count(*) from public.sales_log s
      where s.kind = 'gacha' and s.collection_id = p_collection_id and s.wallet_code = p_wallet)
    / greatest(coalesce((select cards_per_draw from public.collections where collection_id = p_collection_id), 1), 1)
    + coalesce((select sum(oi.pending_draws) from public.shop_order_items oi join public.shop_orders o on o.id = oi.order_id
      where oi.kind = 'gacha' and oi.ref_id = p_collection_id and oi.pending_draws > 0 and o.wallet_code = p_wallet), 0)
  )::int;
$$;
revoke all on function public._collection_draws_used(text, text) from public, anon, authenticated;

-- Checkout side: validate + charge for p_qty x p_pull draws of a pre-order collection, no cards drawn yet
create or replace function public._reserve_preorder_draws(p_username text, p_collection_id text, p_pull integer, p_qty integer)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_user record; v_col record; v_status text; v_cost numeric; v_used int; v_wc text; i int;
begin
  if coalesce(current_setting('blm48.in_checkout', true), '') <> '1' then
    return jsonb_build_object('status','fail','message','This collection is a pre-order. Please order it through the cart.');
  end if;
  if p_pull not in (1, 5) or p_qty < 1 then
    return jsonb_build_object('status','fail','message','Invalid draw count.');
  end if;
  select * into v_user from public.users where username = p_username for update;
  if not found then return jsonb_build_object('status','fail','message','User not found.'); end if;
  select * into v_col from public.collections where collection_id = p_collection_id for update;
  if not found then return jsonb_build_object('status','fail','message','Collection not found.'); end if;

  v_status := case
    when v_col.sale_start_at is not null and now() < v_col.sale_start_at then 'Coming Soon'
    when v_col.sale_end_at is not null and now() > v_col.sale_end_at then 'Closed'
    else v_col.status end;
  if v_status = 'Closed' then return jsonb_build_object('status','fail','message','This collection is closed.'); end if;
  if v_status = 'Coming Soon' then return jsonb_build_object('status','fail','message','This collection is not open yet. Coming soon.'); end if;
  if p_pull = 5 and not coalesce(v_col.allow_x5, true) then
    return jsonb_build_object('status','fail','message','การสุ่มทีละ 5 ไม่สามารถใช้งานได้กับคอลเลกชันนี้');
  end if;

  v_wc := public.wallet_code_of(p_username);
  if v_col.max_draws_per_account is not null then
    v_used := public._collection_draws_used(v_wc, p_collection_id);
    if v_used + p_pull * p_qty > v_col.max_draws_per_account then
      return jsonb_build_object('status','fail',
        'message', format('คุณใช้สิทธิ์การสุ่มของคอลเลกชันนี้ครบแล้ว (สูงสุด %s ครั้งต่อแอคเคาท์ ใช้ไปแล้ว %s ครั้ง)', v_col.max_draws_per_account, v_used));
    end if;
  end if;

  v_cost := case when p_pull = 5 then coalesce(v_col.cost_tokens_x5, v_col.cost_tokens * 5) else v_col.cost_tokens end;
  if v_user.token < v_cost * p_qty then
    return jsonb_build_object('status','fail','message','Insufficient Token balance.');
  end if;

  update public.users set token = token - v_cost * p_qty, updated_at = now() where username = p_username;
  for i in 1..p_qty loop
    insert into public.wallet_logs (wallet_code, action, target, amount)
      values (v_wc, 'Gacha', v_col.collection_name || ' (x' || p_pull || ')', v_cost);
  end loop;
  return jsonb_build_object('status','success');
end $$;
revoke all on function public._reserve_preorder_draws(text, text, integer, integer) from public, anon, authenticated;

-- Ship side: draw p_draws x cards_per_draw cards for one wallet (by rate; stock is not a limit for pre-orders)
create or replace function public._draw_preorder_cards(p_collection_id text, p_wallet text, p_draws integer)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_cpd int; v_pack bigint[]; v_excl bigint[]; v_sum numeric; v_roll numeric; v_cum numeric;
  v_row record; v_item record; v_out jsonb := '[]'::jsonb; i int; j int;
begin
  select greatest(coalesce(cards_per_draw, 1), 1) into v_cpd from public.collections where collection_id = p_collection_id;
  for i in 1..p_draws loop
    v_pack := '{}';
    for j in 1..v_cpd loop
      v_excl := case when exists (select 1 from public.items where collection_id = p_collection_id and rate > 0 and not (id = any(v_pack)))
                     then v_pack else '{}'::bigint[] end;
      select coalesce(sum(rate), 0) into v_sum from public.items
        where collection_id = p_collection_id and rate > 0 and not (id = any(v_excl));
      v_roll := random() * v_sum; v_cum := 0; v_item := null;
      for v_row in select * from public.items where collection_id = p_collection_id and rate > 0 and not (id = any(v_excl)) order by id loop
        v_cum := v_cum + v_row.rate;
        if v_roll < v_cum then v_item := v_row; exit; end if;
      end loop;
      if v_item is null then
        select * into v_item from public.items where collection_id = p_collection_id and rate > 0 and not (id = any(v_excl)) order by id desc limit 1;
      end if;
      v_pack := v_pack || v_item.id::bigint;
      update public.items set stock = greatest(stock - 1, 0), updated_at = now() where id = v_item.id;
      insert into public.sales_log (wallet_code, kind, item_name, collection_id) values (p_wallet, 'gacha', v_item.name, p_collection_id);
      v_out := v_out || jsonb_build_object('kind','item','itemType','Coaster','collectionId',p_collection_id,
        'label',v_item.name,'imageUrl',v_item.image_url,'isSSR',coalesce(v_item.tag = 'SSR', false));
    end loop;
  end loop;
  return v_out;
end $$;
revoke all on function public._draw_preorder_cards(text, text, integer) from public, anon, authenticated;

create or replace function public.admin_ship_collection_preorder(p_admin_username text, p_collection_id text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_col public.collections;
  v_lines int;
  v_order_ids bigint[];
  v_orders int;
  v_buyers int;
  v_sender record;
  v_line record;
  v_missing text;
begin
  if not public.is_admin_or_ceo(p_admin_username) then
    return jsonb_build_object('status','error','message','You do not have permission to do this');
  end if;
  select * into v_col from public.collections where collection_id = p_collection_id and collection_id like 'gacha\_%' for update;
  if not found then return jsonb_build_object('status','error','message','Collection not found'); end if;

  -- owed draws happen now, so the cards must be ready
  if exists (select 1 from public.shop_order_items where kind = 'gacha' and ref_id = p_collection_id and status = 'waiting' and pending_draws > 0) then
    if not exists (select 1 from public.items where collection_id = p_collection_id and rate > 0) then
      return jsonb_build_object('status','error','message','Add the cards (with a rate above 0) before shipping');
    end if;
    select string_agg(name, ', ' order by id) into v_missing from public.items
      where collection_id = p_collection_id and rate > 0 and nullif(btrim(coalesce(image_url, '')), '') is null;
    if v_missing is not null then
      return jsonb_build_object('status','error','message','Add images to these cards before shipping: ' || v_missing);
    end if;

    for v_line in
      select oi.id, oi.pending_draws, o.wallet_code from public.shop_order_items oi join public.shop_orders o on o.id = oi.order_id
       where oi.kind = 'gacha' and oi.ref_id = p_collection_id and oi.status = 'waiting' and oi.pending_draws > 0
       order by oi.id for update of oi
    loop
      update public.shop_order_items
         set rewards = public._draw_preorder_cards(p_collection_id, v_line.wallet_code, v_line.pending_draws) || coalesce(rewards, '[]'::jsonb),
             pending_draws = 0
       where id = v_line.id;
    end loop;
  end if;

  with up as (
    update public.shop_order_items set status = 'ready'
     where kind = 'gacha' and ref_id = p_collection_id and status = 'waiting'
     returning order_id
  ) select count(*), array_agg(distinct order_id) into v_lines, v_order_ids from up;

  if v_lines = 0 then
    return jsonb_build_object('status','error','message','No pre-orders are waiting to ship');
  end if;
  v_orders := coalesce(array_length(v_order_ids, 1), 0);

  select name, profile_img into v_sender from public.users where username = '48-480';
  insert into public.notifications (recipient_username, writer, action, avatar, role, notif_type)
    select public.username_of(b.wallet_code), coalesce(v_sender.name, 'BLM48'),
           'พรีออเดอร์ "' || v_col.collection_name || '" ของคุณจัดส่งแล้ว กด Redeem ในหน้า My Order เพื่อรับของได้เลยค่ะ',
           coalesce(v_col.cover_image, v_sender.profile_img), 'Admin', 'preorder'
      from (select distinct o.wallet_code from public.shop_orders o where o.id = any(v_order_ids)) b;
  get diagnostics v_buyers = row_count;

  update public.collections set preorder_shipped_at = now(), updated_at = now() where collection_id = p_collection_id;

  return jsonb_build_object('status','success','lines', v_lines, 'orders', v_orders, 'buyers', v_buyers,
    'message', format('Shipped %s orders to %s buyers · they can Redeem now', v_orders, v_buyers));
end $function$;

-- Anchor patches
do $$
declare v_def text; r record;
begin
  for r in select * from (values
    -- checkout: pre-order gacha lines reserve draws instead of drawing now
    ('shop_checkout(text,jsonb)'::regprocedure,
     $a$  v_bonus_lines jsonb := '[]'::jsonb;$a$,
     $b$  v_bonus_lines jsonb := '[]'::jsonb;
  v_pending int := 0;$b$),
    ('shop_checkout(text,jsonb)'::regprocedure,
     $a$        select * into v_col from public.collections where collection_id = v_ref;
        for i in 1..v_qty loop
          v_res := public.buy_gacha_item(p_username, v_ref, v_variant);$a$,
     $b$        select * into v_col from public.collections where collection_id = v_ref;
        v_pending := 0;
        if coalesce(v_col.is_preorder, false) and coalesce(v_col.draw_mode, 'normal') <> 'lucky' then
          -- pre-order: charge now, draw the cards when the admin ships
          v_res := public._reserve_preorder_draws(p_username, v_ref, v_variant, v_qty);
          if coalesce(v_res->>'status','') <> 'success' then
            raise exception '%', coalesce(v_res->>'message', 'สั่งซื้อไม่สำเร็จค่ะ');
          end if;
          v_pending := v_variant * v_qty;
        end if;
        for i in 1..(case when v_pending > 0 then 0 else v_qty end) loop
          v_res := public.buy_gacha_item(p_username, v_ref, v_variant);$b$),
    ('shop_checkout(text,jsonb)'::regprocedure,
     $a$preorder_order_id, rewards, status, is_preorder, preorder_bonus)$a$,
     $b$preorder_order_id, rewards, status, is_preorder, preorder_bonus, pending_draws)$b$),
    ('shop_checkout(text,jsonb)'::regprocedure,
     $a$v_preorder_id, v_rewards, v_status, v_is_pre or v_kind = 'preorder', v_bonus);$a$,
     $b$v_preorder_id, v_rewards, v_status, v_is_pre or v_kind = 'preorder', v_bonus,
         case when v_kind = 'gacha' then v_pending else 0 end);$b$),
    -- shop list: draws used includes pending pre-order draws
    ('get_gacha_collections(text)'::regprocedure,
     $a$select count(*) / greatest(coalesce(c.cards_per_draw, 1), 1) as used,$a$,
     $b$select count(*) / greatest(coalesce(c.cards_per_draw, 1), 1)
             + coalesce((select sum(oi.pending_draws) from public.shop_order_items oi join public.shop_orders o on o.id = oi.order_id
                          where p_username is not null and oi.kind = 'gacha' and oi.ref_id = c.collection_id and oi.pending_draws > 0
                            and o.wallet_code = public.wallet_code_of(p_username)), 0) as used,$b$),
    -- admin save: pre-order collections may go on sale without cards / stock / card images
    ('admin_save_collection(text,text,jsonb,jsonb)'::regprocedure,
     $a$  v_pre jsonb; v_pre_on boolean;$a$,
     $b$  v_is_pre boolean; v_pre jsonb; v_pre_on boolean;$b$),
    ('admin_save_collection(text,text,jsonb,jsonb)'::regprocedure,
     $a$  if p_items is not null and coalesce(v_old.draw_mode,'normal') <> 'lucky' then$a$,
     $b$  v_is_pre := coalesce(v_old.draw_mode,'normal') <> 'lucky' and case when jsonb_typeof(p_col->'preorder') = 'object'
    then coalesce((p_col->'preorder'->>'on')::boolean, false) else coalesce(v_old.is_preorder, false) end;
  if p_items is not null and coalesce(v_old.draw_mode,'normal') <> 'lucky' then$b$),
    ('admin_save_collection(text,text,jsonb,jsonb)'::regprocedure,
     $a$if nullif(v_it->>'imageUrl','') is null then raise$a$,
     $b$if nullif(v_it->>'imageUrl','') is null and not v_is_pre then raise$b$),
    ('admin_save_collection(text,text,jsonb,jsonb)'::regprocedure,
     $a$if v_count = 0 then raise$a$,
     $b$if v_count = 0 and not v_is_pre then raise$b$),
    ('admin_save_collection(text,text,jsonb,jsonb)'::regprocedure,
     $a$if not exists (select 1 from public.items where collection_id = v_id and stock > 0 and rate > 0) then$a$,
     $b$if not v_is_pre and not exists (select 1 from public.items where collection_id = v_id and stock > 0 and rate > 0) then$b$),
    ('admin_save_collection(text,text,jsonb,jsonb)'::regprocedure,
     $a$when draw_mode = 'lucky' or v_stock > 0 then 'Open'$a$,
     $b$when draw_mode = 'lucky' or v_is_pre or v_stock > 0 then 'Open'$b$)
  ) t(fn, anchor, repl) loop
    v_def := pg_get_functiondef(r.fn);
    if position(r.repl in v_def) > 0 then continue; end if;
    if position(r.anchor in v_def) = 0 then raise exception 'anchor not found in %: %', r.fn, left(r.anchor, 80); end if;
    execute replace(v_def, r.anchor, r.repl);
  end loop;
end $$;

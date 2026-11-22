-- 2026-11-22: Collections can give more than one card per draw (e.g. 50 Token = random 2 photocards).
-- collections.cards_per_draw (1-10). Draw limits per account still count draws, not cards.

alter table public.collections add column if not exists cards_per_draw integer not null default 1;
alter table public.collections drop constraint if exists collections_cards_per_draw_chk;
alter table public.collections add constraint collections_cards_per_draw_chk check (cards_per_draw between 1 and 10);

create or replace function public.buy_gacha_item(p_username text, p_collection_id text, p_pull_count integer default 1)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_user record;
  v_col record;
  v_item record;
  v_row record;
  v_roll numeric;
  v_cum numeric;
  v_rate_sum numeric;
  v_pool_stock numeric;
  v_new_token numeric;
  v_effective_status text;
  v_cost numeric;
  v_draws_used integer;
  v_results jsonb := '[]'::jsonb;
  v_has_ssr boolean := false;
  v_cpd int;
  v_pack_ids bigint[];
  v_exclude bigint[];
  i int;
  j int;
begin
  if p_username is null or p_collection_id is null then
    return jsonb_build_object('status','fail','message','Missing required information.');
  end if;

  if p_pull_count is null or p_pull_count not in (1, 5) then
    return jsonb_build_object('status','fail','message','Invalid draw count.');
  end if;

  select * into v_user from public.users where username = p_username for update;
  if not found then
    return jsonb_build_object('status','fail','message','User not found.');
  end if;

  select * into v_col from public.collections where collection_id = p_collection_id for update;
  if not found then
    return jsonb_build_object('status','fail','message','Collection not found.');
  end if;

  v_effective_status := case
    when v_col.sale_start_at is not null and now() < v_col.sale_start_at then 'Coming Soon'
    when v_col.sale_end_at is not null and now() > v_col.sale_end_at then 'Closed'
    else v_col.status
  end;

  if v_effective_status = 'Sold Out' then
    return jsonb_build_object('status','fail','message','This collection is sold out.');
  end if;
  if v_effective_status = 'Closed' then
    return jsonb_build_object('status','fail','message','This collection is closed.');
  end if;
  if v_effective_status = 'Coming Soon' then
    return jsonb_build_object('status','fail','message','This collection is not open yet. Coming soon.');
  end if;

  if coalesce(v_col.is_preorder, false) and coalesce(current_setting('blm48.in_checkout', true), '') <> '1' then
    return jsonb_build_object('status','fail','message','This collection is a pre-order. Please order it through the cart.');
  end if;

  if p_pull_count = 5 and not coalesce(v_col.allow_x5, true) then
    return jsonb_build_object('status','fail','message','การสุ่มทีละ 5 ไม่สามารถใช้งานได้กับคอลเลกชันนี้');
  end if;

  if coalesce(v_col.draw_mode, 'normal') = 'lucky' then
    return public._buy_lucky_box(p_username, (select c from public.collections c where c.collection_id = p_collection_id), p_pull_count);
  end if;

  v_cpd := greatest(coalesce(v_col.cards_per_draw, 1), 1);

  if v_col.max_draws_per_account is not null then
    select count(*) / v_cpd into v_draws_used from public.sales_log
      where kind = 'gacha' and collection_id = p_collection_id and wallet_code = public.wallet_code_of(p_username);

    if v_draws_used + p_pull_count > v_col.max_draws_per_account then
      return jsonb_build_object(
        'status','fail',
        'message', format('คุณใช้สิทธิ์การสุ่มของคอลเลกชันนี้ครบแล้ว (สูงสุด %s ครั้งต่อแอคเคาท์ ใช้ไปแล้ว %s ครั้ง)', v_col.max_draws_per_account, v_draws_used)
      );
    end if;
  end if;

  v_cost := case when p_pull_count = 5 then coalesce(v_col.cost_tokens_x5, v_col.cost_tokens * 5) else v_col.cost_tokens end;

  if v_user.token < v_cost then
    return jsonb_build_object('status','fail','message','Insufficient Token balance.');
  end if;

  select coalesce(sum(stock), 0) into v_pool_stock from public.items where collection_id = p_collection_id and stock > 0;
  if v_pool_stock < p_pull_count * v_cpd then
    return jsonb_build_object('status','fail','message','Not enough stock remaining for this draw.');
  end if;

  for i in 1..p_pull_count loop
    v_pack_ids := '{}';
    for j in 1..v_cpd loop
      -- cards in the same pack are different from each other while other cards still have stock
      v_exclude := case when exists (select 1 from public.items where collection_id = p_collection_id and stock > 0 and rate > 0 and not (id = any(v_pack_ids)))
                        then v_pack_ids else '{}'::bigint[] end;

      select coalesce(sum(rate), 0) into v_rate_sum from public.items
        where collection_id = p_collection_id and stock > 0 and not (id = any(v_exclude));
      exit when v_rate_sum <= 0;

      v_roll := random() * v_rate_sum;
      v_cum := 0;
      v_item := null;
      for v_row in select * from public.items
          where collection_id = p_collection_id and stock > 0 and not (id = any(v_exclude)) order by id loop
        v_cum := v_cum + coalesce(v_row.rate, 0);
        if v_roll < v_cum then
          v_item := v_row;
          exit;
        end if;
      end loop;

      if v_item is null then
        select * into v_item from public.items
          where collection_id = p_collection_id and stock > 0 and not (id = any(v_exclude)) order by id limit 1;
      end if;

      exit when v_item is null;
      v_pack_ids := v_pack_ids || v_item.id::bigint;

      update public.items set stock = stock - 1, updated_at = now() where id = v_item.id;

      insert into public.inventory (wallet_code, item_type, collection_id, item_name, image_url)
        values (public.wallet_code_of(p_username), 'Coaster', p_collection_id, v_item.name, v_item.image_url);

      -- permanent sales record (kept even if the user later deletes the inventory item); also counts draws per account
      insert into public.sales_log (wallet_code, kind, item_name, collection_id)
        values (public.wallet_code_of(p_username), 'gacha', v_item.name, p_collection_id);

      if v_item.tag = 'SSR' then
        v_has_ssr := true;
      end if;

      v_results := v_results || jsonb_build_object(
        'itemName', v_item.name,
        'itemImg', v_item.image_url,
        'isSSR', v_item.tag = 'SSR'
      );
    end loop;
  end loop;

  update public.users set token = token - v_cost, updated_at = now()
    where username = p_username returning token into v_new_token;

  insert into public.wallet_logs (wallet_code, action, target, amount)
    values (public.wallet_code_of(p_username), 'Gacha', v_col.collection_name || ' (x' || p_pull_count || ')', v_cost);

  if not exists (select 1 from public.items where collection_id = p_collection_id and stock > 0) then
    update public.collections set status = 'Sold Out', updated_at = now() where collection_id = p_collection_id;
  end if;

  return jsonb_build_object(
    'status', 'success',
    'items', v_results,
    'hasSSR', v_has_ssr,
    'collectionName', v_col.collection_name,
    'newToken', v_new_token,
    'itemName', v_results->0->>'itemName',
    'itemImg', v_results->0->>'itemImg',
    'itemType', 'Coaster'
  );
end;
$function$;

-- Patch the admin + shop RPCs in place (anchor replace, same style as collection_preorder.sql)
do $$
declare
  v_def text;
  v_fn regprocedure;
  r record;
begin
  for r in select * from (values
    ('admin_get_collection(text,text)'::regprocedure,
     $a$'allowX5', coalesce(c.allow_x5, true),$a$,
     $b$'allowX5', coalesce(c.allow_x5, true), 'cardsPerDraw', coalesce(c.cards_per_draw, 1),$b$),
    ('admin_list_collections(text)'::regprocedure,
     $a$'allowX5', coalesce(c.allow_x5, true),$a$,
     $b$'allowX5', coalesce(c.allow_x5, true), 'cardsPerDraw', coalesce(c.cards_per_draw, 1),$b$),
    ('admin_save_collection(text,text,jsonb,jsonb)'::regprocedure,
     $a$allow_x5 = v_allow5,$a$,
     $b$allow_x5 = v_allow5,
    cards_per_draw = case when p_col ? 'cardsPerDraw' then greatest(1, least(10, coalesce(nullif(p_col->>'cardsPerDraw','')::int, 1))) else cards_per_draw end,$b$),
    ('get_gacha_collections(text)'::regprocedure,
     $a$'AllowX5', coalesce(c.allow_x5, true),$a$,
     $b$'AllowX5', coalesce(c.allow_x5, true),
    'CardsPerDraw', coalesce(c.cards_per_draw, 1),$b$),
    ('get_gacha_collections(text)'::regprocedure,
     $a$select count(*) as used,$a$,
     $b$select count(*) / greatest(coalesce(c.cards_per_draw, 1), 1) as used,$b$)
  ) t(fn, anchor, repl) loop
    v_def := pg_get_functiondef(r.fn);
    if position(r.repl in v_def) > 0 then continue; end if; -- already patched
    if position(r.anchor in v_def) = 0 then raise exception 'anchor not found in %: %', r.fn, r.anchor; end if;
    execute replace(v_def, r.anchor, r.repl);
  end loop;
end $$;

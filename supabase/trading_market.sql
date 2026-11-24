-- 🔁 Trading Market (2026-11-24, migration trading_market)
-- Coaster Trade → Trading Market: trade more item types, BLM48 and NPT48.
-- User (2026-11-24): "ปรับให้เป็นรูปแบบ Trading Market ที่สามารถ Trade สินค้าได้หลายประเภทมากขึ้น
--                     และสามารถ Trade ได้ทั้ง BLM48 และ NPT48"
-- * What can be traded is now a config table, trade_categories (collections.category → type label).
--   Seeded: Coaster, BLM48 PhotoCard, PhotoCard, BLM48 SSR Photo, NPT48 Badge, NPT48 PhotoCard, Badge, BLM48 Badge.
--   To open another category later: insert into trade_categories (...). To pause one: enabled = false.
--   Not tradable (on purpose): Cafe merch, Photobook, PhotoSet, Poster, Thank You Card, Preorder, Ticket Stub.
-- * NPT48 exclusion removed: group comes from collections.group_name (BLM48 / NPT48 / Both); cross-group swaps OK.
-- * Rule kept: same rarity only (Normal ↔ Normal, SSR ↔ SSR), across any type/group.
--   SSR = items.tag 'SSR', or every item of a category with force_rarity 'SSR' (BLM48 SSR Photo).
-- * "Any" listings can be narrowed: want_group (BLM48/NPT48) and/or want_type (Coaster/PhotoCard/Badge/SSR Photo).
-- * Escrow keeps the real inventory.item_type (was hard-coded 'Coaster'); old rows default to 'Coaster'.
-- * RPC names unchanged (coaster_*), page file stays coaster_trade.html (links in notifications/profile keep working).

create table if not exists public.trade_categories (
  category text primary key,              -- collections.category
  type_label text not null,               -- shown on the market: Coaster / PhotoCard / Badge / SSR Photo
  force_rarity text check (force_rarity in ('Normal','SSR')),
  enabled boolean not null default true,
  sort int not null default 100
);
alter table public.trade_categories enable row level security;
grant select, insert, update, delete on public.trade_categories to service_role;

insert into public.trade_categories (category, type_label, force_rarity, sort) values
  ('Coaster',          'Coaster',   null,  10),
  ('BLM48 PhotoCard',  'PhotoCard', null,  20),
  ('PhotoCard',        'PhotoCard', null,  21),
  ('NPT48 PhotoCard',  'PhotoCard', null,  22),
  ('NPT48 Badge',      'Badge',     null,  30),
  ('BLM48 Badge',      'Badge',     null,  31),
  ('Badge',            'Badge',     null,  32),
  ('BLM48 SSR Photo',  'SSR Photo', 'SSR', 40)
on conflict (category) do nothing;

alter table public.coaster_trades
  add column if not exists offer_item_type text not null default 'Coaster',
  add column if not exists taker_item_type text,
  add column if not exists want_group text check (want_group in ('BLM48','NPT48')),
  add column if not exists want_type text;
alter table public.coaster_trade_offers
  add column if not exists item_type text not null default 'Coaster';

-- type + group of a collection (null type = not tradable)
create or replace function public._trade_item_meta(p_collection_id text) returns jsonb
language sql stable security definer set search_path to 'public' as $$
  select jsonb_build_object('type', tc.type_label, 'group', coalesce(c.group_name, 'BLM48'), 'sort', coalesce(tc.sort, 999))
    from public.collections c
    left join public.trade_categories tc on tc.category = c.category and tc.enabled
   where c.collection_id = p_collection_id
$$;

create or replace function public._trade_item_json(p_collection_id text, p_name text, p_image text) returns jsonb
language sql stable security definer set search_path to 'public' as $$
  select jsonb_build_object('collectionId', p_collection_id, 'name', p_name,
           'collectionName', c.collection_name,
           'imageUrl', coalesce(p_image, (select it.image_url from public.items it where it.collection_id = p_collection_id and it.name = p_name limit 1)),
           'type', tc.type_label, 'group', coalesce(c.group_name, 'BLM48'))
    from (select 1) x
    left join public.collections c on c.collection_id = p_collection_id
    left join public.trade_categories tc on tc.category = c.category
$$;

-- rarity of a tradable item, null when not tradable
create or replace function public._coaster_rarity(p_collection_id text, p_name text) returns text
language sql stable security definer set search_path to 'public' as $$
  select coalesce(tc.force_rarity, case when coalesce(it.tag,'') = 'SSR' then 'SSR' else 'Normal' end)
    from public.items it
    join public.collections c on c.collection_id = it.collection_id
    join public.trade_categories tc on tc.category = c.category and tc.enabled
   where it.collection_id = p_collection_id and it.name = p_name
     and public._coaster_collection_released(c.collection_id)
   limit 1
$$;

-- does an item fit a listing's "Any" filter (group / type)?
create or replace function public._trade_fits_scope(p_collection_id text, p_group text, p_type text) returns boolean
language sql stable security definer set search_path to 'public' as $$
  select (p_group is null or m->>'group' = p_group or m->>'group' = 'Both')
     and (p_type is null or m->>'type' = p_type)
    from (select public._trade_item_meta(p_collection_id) m) s
$$;

create or replace function public._coaster_offer_json(o public.coaster_trade_offers) returns jsonb
language sql stable security definer set search_path to 'public' as $$
  select jsonb_build_object('id', o.id, 'tradeId', o.trade_id, 'status', o.status, 'createdAt', o.created_at, 'closedAt', o.closed_at,
    'item', public._trade_item_json(o.collection_id, o.item_name, o.image_url),
    'offerer', jsonb_build_object('username', u.username, 'name', coalesce(u.name, u.username), 'img', u.profile_img))
  from (select 1) x
  left join public.user_wallets w on w.wallet_code = o.offerer_wallet
  left join public.users u on u.username = w.username
$$;

create or replace function public._coaster_trade_json(t public.coaster_trades, p_wc text) returns jsonb
language sql stable security definer set search_path to 'public' as $$
  select jsonb_build_object(
    'id', t.id, 'createdAt', t.created_at, 'status', t.status, 'rarity', t.rarity, 'mine', t.owner_wallet = p_wc,
    'offer', public._trade_item_json(t.offer_collection_id, t.offer_item_name, t.offer_image_url),
    'want', coalesce((select jsonb_agg(public._trade_item_json(w->>'collectionId', w->>'name', null))
                        from jsonb_array_elements(t.want) w), '[]'::jsonb),
    'wantGroup', t.want_group, 'wantType', t.want_type,
    'owner', jsonb_build_object('username', ou.username, 'name', coalesce(ou.name, ou.username), 'img', ou.profile_img),
    'taker', case when t.taker_wallet is not null then jsonb_build_object('username', tu.username, 'name', coalesce(tu.name, tu.username),
                  'img', tu.profile_img, 'mine', t.taker_wallet = p_wc) end,
    'received', case when t.taker_wallet is not null then public._trade_item_json(t.taker_collection_id, t.taker_item_name, t.taker_image_url) end,
    'doneAt', t.done_at,
    'offerCount', (select count(*) from public.coaster_trade_offers o where o.trade_id = t.id and o.status = 'pending'),
    'offers', case when t.owner_wallet = p_wc then coalesce((select jsonb_agg(public._coaster_offer_json(o) order by o.created_at)
                  from public.coaster_trade_offers o where o.trade_id = t.id and o.status = 'pending'), '[]'::jsonb) else '[]'::jsonb end,
    'myOffer', (select public._coaster_offer_json(o) from public.coaster_trade_offers o
                 where o.trade_id = t.id and o.offerer_wallet = p_wc and o.status = 'pending' limit 1))
  from (select 1) x
  left join public.user_wallets ow on ow.wallet_code = t.owner_wallet
  left join public.users ou on ou.username = ow.username
  left join public.user_wallets tw on tw.wallet_code = t.taker_wallet
  left join public.users tu on tu.username = tw.username
$$;

-- board: open listings + my status + the type list for filter chips
create or replace function public.get_coaster_trade_board(p_username text) returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare v_wc text := public.wallet_code_of(p_username);
begin
  return jsonb_build_object(
    'me', public._coaster_trade_status(p_username),
    'types', coalesce((select jsonb_agg(type_label order by s) from (
                select tc.type_label, min(tc.sort) s from public.trade_categories tc
                 where tc.enabled and exists (select 1 from public.collections c where c.category = tc.category
                                               and public._coaster_collection_released(c.collection_id))
                 group by tc.type_label) q), '[]'::jsonb),
    'listings', coalesce((select jsonb_agg(public._coaster_trade_json(t, v_wc) order by t.created_at desc)
                            from (select * from public.coaster_trades where status = 'open' order by created_at desc limit 300) t), '[]'::jsonb));
end;
$$;

-- my tradable items grouped by design
create or replace function public.get_my_tradable_coasters(p_username text) returns jsonb
language sql stable security definer set search_path to 'public' as $$
  select coalesce(jsonb_agg(x order by (x->>'rarity') desc, (x->>'sort')::int, x->>'collectionName', x->>'name'), '[]'::jsonb) from (
    select jsonb_build_object('collectionId', i.collection_id, 'collectionName', c.collection_name, 'name', i.item_name,
             'imageUrl', min(i.image_url),
             'rarity', coalesce(tc.force_rarity, case when coalesce(it.tag,'') = 'SSR' then 'SSR' else 'Normal' end),
             'type', tc.type_label, 'group', coalesce(c.group_name, 'BLM48'), 'sort', tc.sort,
             'count', count(*), 'inventoryId', min(i.id)) x
      from public.inventory i
      join public.collections c on c.collection_id = i.collection_id
      join public.trade_categories tc on tc.category = c.category and tc.enabled
      join public.items it on it.collection_id = i.collection_id and it.name = i.item_name
     where i.wallet_code = public.wallet_code_of(p_username)
       and coalesce(i.item_type, '') <> 'Preorder'
       and public._coaster_collection_released(c.collection_id)
     group by i.collection_id, c.collection_name, c.group_name, i.item_name, it.tag, tc.force_rarity, tc.type_label, tc.sort
  ) s
$$;

-- every tradable design (for the "Want" picker)
create or replace function public.get_coaster_trade_catalog() returns jsonb
language sql stable security definer set search_path to 'public' as $$
  select coalesce(jsonb_agg(jsonb_build_object('collectionId', it.collection_id, 'collectionName', c.collection_name,
           'name', it.name, 'imageUrl', it.image_url,
           'rarity', coalesce(tc.force_rarity, case when coalesce(it.tag,'') = 'SSR' then 'SSR' else 'Normal' end),
           'type', tc.type_label, 'group', coalesce(c.group_name, 'BLM48'))
           order by tc.sort, c.collection_name, it.id), '[]'::jsonb)
    from public.items it
    join public.collections c on c.collection_id = it.collection_id
    join public.trade_categories tc on tc.category = c.category and tc.enabled
   where public._coaster_collection_released(c.collection_id)
$$;

drop function if exists public.create_coaster_trade(text, bigint, jsonb);
create or replace function public.create_coaster_trade(p_username text, p_inventory_id bigint, p_want jsonb,
                                                       p_want_group text default null, p_want_type text default null) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare
  v_st jsonb;
  v_wc text := public.wallet_code_of(p_username);
  inv public.inventory;
  v_rarity text;
  v_want jsonb := '[]'::jsonb;
  v_group text := nullif(p_want_group, '');
  v_type text := nullif(p_want_type, '');
  w jsonb;
  v_id bigint;
begin
  perform 1 from public.users where username = p_username for update;
  v_st := public._coaster_trade_status(p_username);
  if not (v_st->>'eligible')::boolean then return jsonb_build_object('status','fail','message', v_st->>'reason'); end if;
  if (v_st->>'usedToday')::int >= 3 then return jsonb_build_object('status','fail','message','You have used all 3 trades for today. Come back tomorrow.'); end if;
  if (v_st->>'openCount')::int >= 5 then return jsonb_build_object('status','fail','message','You can have up to 5 open listings at a time.'); end if;

  select * into inv from public.inventory where id = p_inventory_id and wallet_code = v_wc
     and coalesce(item_type, '') <> 'Preorder' for update;
  if not found then return jsonb_build_object('status','fail','message','This item is not in your Inventory.'); end if;
  v_rarity := public._coaster_rarity(inv.collection_id, inv.item_name);
  if v_rarity is null then return jsonb_build_object('status','fail','message','This item cannot be traded.'); end if;

  if p_want is not null and jsonb_typeof(p_want) = 'array' and jsonb_array_length(p_want) > 0 then
    if jsonb_array_length(p_want) > 3 then return jsonb_build_object('status','fail','message','You can choose up to 3 wanted items.'); end if;
    for w in select * from jsonb_array_elements(p_want) loop
      if public._coaster_rarity(w->>'collectionId', w->>'name') is distinct from v_rarity then
        return jsonb_build_object('status','fail','message','Wanted items must be the same rarity as yours.');
      end if;
      if w->>'collectionId' = inv.collection_id and w->>'name' = inv.item_name then
        return jsonb_build_object('status','fail','message','You cannot want the same item you are offering.');
      end if;
      if not v_want @> jsonb_build_array(jsonb_build_object('collectionId', w->>'collectionId', 'name', w->>'name')) then
        v_want := v_want || jsonb_build_array(jsonb_build_object('collectionId', w->>'collectionId', 'name', w->>'name'));
      end if;
    end loop;
    v_group := null; v_type := null;      -- specific picks: the filter does not apply
  else
    if v_group is not null and v_group not in ('BLM48','NPT48') then
      return jsonb_build_object('status','fail','message','Unknown group.');
    end if;
    if v_type is not null and not exists (select 1 from public.trade_categories where type_label = v_type and enabled) then
      return jsonb_build_object('status','fail','message','Unknown item type.');
    end if;
  end if;

  delete from public.inventory where id = inv.id;
  insert into public.coaster_trades (owner_wallet, offer_collection_id, offer_item_name, offer_image_url, offer_file_url,
                                     offer_item_type, rarity, want, want_group, want_type)
    values (v_wc, inv.collection_id, inv.item_name, inv.image_url, inv.file_url,
            coalesce(inv.item_type, 'Coaster'), v_rarity, v_want, v_group, v_type)
    returning id into v_id;
  return jsonb_build_object('status','success','id', v_id);
end;
$$;

create or replace function public._coaster_offer_return(o public.coaster_trade_offers, p_status text, p_msg text) returns void
language plpgsql security definer set search_path to 'public' as $$
declare v_user text;
begin
  update public.coaster_trade_offers set status = p_status, closed_at = now() where id = o.id;
  insert into public.inventory (wallet_code, item_type, collection_id, item_name, image_url, file_url)
    values (o.offerer_wallet, coalesce(o.item_type, 'Coaster'), o.collection_id, o.item_name, o.image_url, o.file_url);
  if p_msg is not null then
    select username into v_user from public.user_wallets where wallet_code = o.offerer_wallet;
    if v_user is not null then
      insert into public.notifications (writer, action, avatar, role, recipient_username, notif_type)
        values ('BLM48', p_msg, o.image_url, 'Admin', v_user, 'trade');
    end if;
  end if;
end;
$$;

create or replace function public.make_coaster_offer(p_username text, p_trade_id bigint, p_inventory_id bigint) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare
  v_st jsonb;
  v_wc text := public.wallet_code_of(p_username);
  t public.coaster_trades;
  inv public.inventory;
  v_owner_user text;
  v_name text;
  v_id bigint;
begin
  perform 1 from public.users where username = p_username for update;
  v_st := public._coaster_trade_status(p_username);
  if not (v_st->>'eligible')::boolean then return jsonb_build_object('status','fail','message', v_st->>'reason'); end if;
  if (v_st->>'usedToday')::int >= 3 then return jsonb_build_object('status','fail','message','You have used all 3 trades for today. Come back tomorrow.'); end if;
  if (v_st->>'pendingOffers')::int >= 5 then return jsonb_build_object('status','fail','message','You can have up to 5 pending offers at a time.'); end if;

  select * into t from public.coaster_trades where id = p_trade_id for update;
  if not found or t.status <> 'open' then return jsonb_build_object('status','fail','message','This listing was already traded or cancelled.'); end if;
  if t.owner_wallet = v_wc then return jsonb_build_object('status','fail','message','You cannot trade with your own listing.'); end if;
  if exists (select 1 from public.coaster_trade_offers where trade_id = t.id and offerer_wallet = v_wc and status = 'pending') then
    return jsonb_build_object('status','fail','message','You already sent an offer for this listing.');
  end if;

  select * into inv from public.inventory where id = p_inventory_id and wallet_code = v_wc
     and coalesce(item_type, '') <> 'Preorder' for update;
  if not found then return jsonb_build_object('status','fail','message','This item is not in your Inventory.'); end if;
  if public._coaster_rarity(inv.collection_id, inv.item_name) is distinct from t.rarity then
    return jsonb_build_object('status','fail','message','You must offer an item of the same rarity.');
  end if;
  if inv.collection_id = t.offer_collection_id and inv.item_name = t.offer_item_name then
    return jsonb_build_object('status','fail','message','You cannot offer the same item as the listing.');
  end if;
  if jsonb_array_length(t.want) > 0 then
    if not t.want @> jsonb_build_array(jsonb_build_object('collectionId', inv.collection_id, 'name', inv.item_name)) then
      return jsonb_build_object('status','fail','message','This is not an item the owner wants.');
    end if;
  elsif not public._trade_fits_scope(inv.collection_id, t.want_group, t.want_type) then
    return jsonb_build_object('status','fail','message','This is not an item the owner wants.');
  end if;

  delete from public.inventory where id = inv.id;
  insert into public.coaster_trade_offers (trade_id, offerer_wallet, collection_id, item_name, image_url, file_url, item_type)
    values (t.id, v_wc, inv.collection_id, inv.item_name, inv.image_url, inv.file_url, coalesce(inv.item_type, 'Coaster'))
    returning id into v_id;

  select username into v_owner_user from public.user_wallets where wallet_code = t.owner_wallet;
  select coalesce(name, username) into v_name from public.users where username = p_username;
  if v_owner_user is not null then
    insert into public.notifications (writer, action, avatar, role, recipient_username, notif_type)
      values ('BLM48', 'New trade offer: ' || v_name || ' offers ' || inv.item_name || ' for your ' || t.offer_item_name
                       || '. Open Trading Market to accept or decline.', inv.image_url, 'Admin', v_owner_user, 'trade');
  end if;
  return jsonb_build_object('status','success','id', v_id);
end;
$$;

create or replace function public.accept_coaster_offer(p_username text, p_offer_id bigint) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare
  v_wc text := public.wallet_code_of(p_username);
  o public.coaster_trade_offers;
  t public.coaster_trades;
  r public.coaster_trade_offers;
  v_user text;
begin
  select * into o from public.coaster_trade_offers where id = p_offer_id;
  if not found then return jsonb_build_object('status','fail','message','Offer not found.'); end if;
  select * into t from public.coaster_trades where id = o.trade_id and owner_wallet = v_wc for update;
  if not found then return jsonb_build_object('status','fail','message','Offer not found.'); end if;
  if t.status <> 'open' then return jsonb_build_object('status','fail','message','This listing is already closed.'); end if;
  select * into o from public.coaster_trade_offers where id = p_offer_id for update;
  if o.status <> 'pending' then return jsonb_build_object('status','fail','message','This offer was withdrawn.'); end if;

  -- swap: offered item → poster, listed item → offerer (each keeps its own item_type)
  insert into public.inventory (wallet_code, item_type, collection_id, item_name, image_url, file_url)
    values (t.owner_wallet, coalesce(o.item_type, 'Coaster'), o.collection_id, o.item_name, o.image_url, o.file_url),
           (o.offerer_wallet, coalesce(t.offer_item_type, 'Coaster'), t.offer_collection_id, t.offer_item_name, t.offer_image_url, t.offer_file_url);
  update public.coaster_trade_offers set status = 'accepted', closed_at = now() where id = o.id;
  update public.coaster_trades set status = 'done', done_at = now(), taker_wallet = o.offerer_wallet,
         taker_collection_id = o.collection_id, taker_item_name = o.item_name,
         taker_image_url = o.image_url, taker_file_url = o.file_url, taker_item_type = o.item_type
   where id = t.id;

  select username into v_user from public.user_wallets where wallet_code = o.offerer_wallet;
  if v_user is not null then
    insert into public.notifications (writer, action, avatar, role, recipient_username, notif_type)
      values ('BLM48', 'Trade complete! Your offer was accepted: you got ' || t.offer_item_name || ' for ' || o.item_name
                       || '. Check your Inventory.', t.offer_image_url, 'Admin', v_user, 'trade');
  end if;

  for r in select * from public.coaster_trade_offers where trade_id = t.id and status = 'pending' for update loop
    perform public._coaster_offer_return(r, 'returned',
      t.offer_item_name || ' was traded to another fan. ' || r.item_name || ' is back in your Inventory.');
  end loop;
  return jsonb_build_object('status','success','received', jsonb_build_object('name', o.item_name, 'imageUrl', o.image_url));
end;
$$;

create or replace function public.cancel_coaster_trade(p_username text, p_trade_id bigint) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare
  v_wc text := public.wallet_code_of(p_username);
  t public.coaster_trades;
  r public.coaster_trade_offers;
begin
  select * into t from public.coaster_trades where id = p_trade_id and owner_wallet = v_wc for update;
  if not found then return jsonb_build_object('status','fail','message','Listing not found.'); end if;
  if t.status <> 'open' then return jsonb_build_object('status','fail','message','This listing is already closed.'); end if;
  update public.coaster_trades set status = 'cancelled', cancelled_at = now() where id = t.id;
  insert into public.inventory (wallet_code, item_type, collection_id, item_name, image_url, file_url)
    values (v_wc, coalesce(t.offer_item_type, 'Coaster'), t.offer_collection_id, t.offer_item_name, t.offer_image_url, t.offer_file_url);
  for r in select * from public.coaster_trade_offers where trade_id = t.id and status = 'pending' for update loop
    perform public._coaster_offer_return(r, 'returned',
      'The listing for ' || t.offer_item_name || ' was cancelled. ' || r.item_name || ' is back in your Inventory.');
  end loop;
  return jsonb_build_object('status','success');
end;
$$;

grant execute on function public.create_coaster_trade(text,bigint,jsonb,text,text) to anon, authenticated, service_role;
revoke execute on function public._trade_item_meta(text) from public, anon, authenticated;
revoke execute on function public._trade_item_json(text,text,text) from public, anon, authenticated;
revoke execute on function public._trade_fits_scope(text,text,text) from public, anon, authenticated;
revoke execute on function public._coaster_rarity(text,text) from public, anon, authenticated;
revoke execute on function public._coaster_offer_json(public.coaster_trade_offers) from public, anon, authenticated;
revoke execute on function public._coaster_trade_json(public.coaster_trades,text) from public, anon, authenticated;
revoke execute on function public._coaster_offer_return(public.coaster_trade_offers,text,text) from public, anon, authenticated;

-- 🔁 Coaster Trade board (2026-11-08, migration coaster_trade)
-- Public board: a fan lists ONE Coaster ("มี X") and what they want ("อยากได้ Y" = up to 3 specific designs,
-- or any design of the same rarity). Anyone else who owns a matching Coaster taps it → instant swap.
-- Rules (user, 2026-11-08):
--   * same rarity only (Normal↔Normal, SSR↔SSR; SSR = items.tag 'SSR'), any Coaster collection
--   * NPT48 badges/photocards are NOT tradable (only collections.category = 'Coaster', id not gacha_npt%)
--   * free, no fee
--   * daily limit: 3 trade actions per account per Bangkok day (posting a listing or taking one);
--     a cancelled listing gives its quota back; max 5 open listings at once
--   * account must be 14+ days old (user_wallets.created_at — users has no created_at) and active
-- 2026-11-08 (migration coaster_trade_english_messages): all user-facing messages switched to English.
-- Escrow: the listed Coaster is removed from inventory while the listing is open (cannot be traded twice);
-- cancel puts it back. Ledger stores wallet_code (never username).

create table if not exists public.coaster_trades (
  id bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  owner_wallet text not null,
  offer_collection_id text not null,
  offer_item_name text not null,
  offer_image_url text,
  offer_file_url text,
  rarity text not null check (rarity in ('Normal','SSR')),
  want jsonb not null default '[]'::jsonb,          -- [] = any same-rarity design, else [{collectionId,name}] (≤3)
  status text not null default 'open' check (status in ('open','done','cancelled')),
  taker_wallet text,
  taker_collection_id text,
  taker_item_name text,
  taker_image_url text,
  taker_file_url text,
  done_at timestamptz,
  cancelled_at timestamptz
);
create index if not exists coaster_trades_open_idx on public.coaster_trades (status, created_at desc);
create index if not exists coaster_trades_owner_idx on public.coaster_trades (owner_wallet, created_at desc);
create index if not exists coaster_trades_taker_idx on public.coaster_trades (taker_wallet, done_at desc);
alter table public.coaster_trades enable row level security;
grant select, insert, update, delete on public.coaster_trades to service_role;

alter table public.notifications drop constraint notifications_notif_type_check;
alter table public.notifications add constraint notifications_notif_type_check
  check (notif_type = any (array['post','comment','reply','mention','admin','shop','wallet','preorder','theater','trade']));

-- rarity of a tradable design, null when not tradable
create or replace function public._coaster_rarity(p_collection_id text, p_name text) returns text
language sql stable security definer set search_path to 'public' as $$
  select case when coalesce(it.tag,'') = 'SSR' then 'SSR' else 'Normal' end
    from public.items it join public.collections c on c.collection_id = it.collection_id
   where it.collection_id = p_collection_id and it.name = p_name
     and c.category = 'Coaster' and c.collection_id not ilike 'gacha_npt%'
   limit 1
$$;

-- eligibility + today's quota
create or replace function public._coaster_trade_status(p_username text) returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare
  v_wc text := public.wallet_code_of(p_username);
  v_created timestamptz;
  v_status text;
  v_today date := (now() at time zone 'Asia/Bangkok')::date;
  v_used int;
  v_open int;
  v_reason text;
begin
  select status into v_status from public.users where username = p_username;
  select created_at into v_created from public.user_wallets where username = p_username;
  select count(*) into v_used from public.coaster_trades t
   where (t.owner_wallet = v_wc and t.status <> 'cancelled' and (t.created_at at time zone 'Asia/Bangkok')::date = v_today)
      or (t.taker_wallet = v_wc and (t.done_at at time zone 'Asia/Bangkok')::date = v_today);
  select count(*) into v_open from public.coaster_trades where owner_wallet = v_wc and status = 'open';
  if v_wc is null or v_status is null then v_reason := 'Account not found';
  elsif v_status <> 'active' then v_reason := 'This account cannot use trading';
  elsif v_created is null or v_created > now() - interval '14 days' then
    v_reason := 'Trading unlocks when your account is 14 days old (' ||
      to_char((coalesce(v_created, now()) + interval '14 days') at time zone 'Asia/Bangkok', 'DD/MM/YYYY') || ')';
  end if;
  return jsonb_build_object('walletCode', v_wc, 'eligible', v_reason is null, 'reason', v_reason,
    'usedToday', v_used, 'dailyLimit', 3, 'openCount', v_open, 'maxOpen', 5);
end;
$$;

create or replace function public._coaster_trade_json(t public.coaster_trades, p_wc text) returns jsonb
language sql stable security definer set search_path to 'public' as $$
  select jsonb_build_object(
    'id', t.id, 'createdAt', t.created_at, 'status', t.status, 'rarity', t.rarity, 'mine', t.owner_wallet = p_wc,
    'offer', jsonb_build_object('collectionId', t.offer_collection_id, 'collectionName', oc.collection_name,
                                'name', t.offer_item_name, 'imageUrl', t.offer_image_url),
    'want', coalesce((select jsonb_agg(jsonb_build_object('collectionId', w->>'collectionId', 'name', w->>'name',
                         'collectionName', wc.collection_name, 'imageUrl', wi.image_url))
                        from jsonb_array_elements(t.want) w
                        left join public.collections wc on wc.collection_id = w->>'collectionId'
                        left join public.items wi on wi.collection_id = w->>'collectionId' and wi.name = w->>'name'), '[]'::jsonb),
    'owner', jsonb_build_object('username', ou.username, 'name', coalesce(ou.name, ou.username), 'img', ou.profile_img),
    'taker', case when t.taker_wallet is not null then jsonb_build_object('username', tu.username, 'name', coalesce(tu.name, tu.username),
                  'img', tu.profile_img, 'mine', t.taker_wallet = p_wc) end,
    'received', case when t.taker_wallet is not null then jsonb_build_object('collectionId', t.taker_collection_id,
                  'name', t.taker_item_name, 'imageUrl', t.taker_image_url) end,
    'doneAt', t.done_at)
  from (select 1) x
  left join public.collections oc on oc.collection_id = t.offer_collection_id
  left join public.user_wallets ow on ow.wallet_code = t.owner_wallet
  left join public.users ou on ou.username = ow.username
  left join public.user_wallets tw on tw.wallet_code = t.taker_wallet
  left join public.users tu on tu.username = tw.username
$$;

-- board: open listings (newest first) + my status
create or replace function public.get_coaster_trade_board(p_username text) returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare v_wc text := public.wallet_code_of(p_username);
begin
  return jsonb_build_object(
    'me', public._coaster_trade_status(p_username),
    'listings', coalesce((select jsonb_agg(public._coaster_trade_json(t, v_wc) order by t.created_at desc)
                            from (select * from public.coaster_trades where status = 'open' order by created_at desc limit 300) t), '[]'::jsonb));
end;
$$;

-- my tradable Coasters grouped by design: [{collectionId, collectionName, name, imageUrl, rarity, count, inventoryId}]
create or replace function public.get_my_tradable_coasters(p_username text) returns jsonb
language sql stable security definer set search_path to 'public' as $$
  select coalesce(jsonb_agg(x order by x->>'rarity' desc, x->>'collectionName', x->>'name'), '[]'::jsonb) from (
    select jsonb_build_object('collectionId', i.collection_id, 'collectionName', c.collection_name, 'name', i.item_name,
             'imageUrl', min(i.image_url), 'rarity', case when coalesce(it.tag,'') = 'SSR' then 'SSR' else 'Normal' end,
             'count', count(*), 'inventoryId', min(i.id)) x
      from public.inventory i
      join public.collections c on c.collection_id = i.collection_id and c.category = 'Coaster' and c.collection_id not ilike 'gacha_npt%'
      join public.items it on it.collection_id = i.collection_id and it.name = i.item_name
     where i.wallet_code = public.wallet_code_of(p_username) and i.item_type = 'Coaster'
     group by i.collection_id, c.collection_name, i.item_name, it.tag
  ) s
$$;

-- every tradable design (for the "อยากได้" picker)
create or replace function public.get_coaster_trade_catalog() returns jsonb
language sql stable security definer set search_path to 'public' as $$
  select coalesce(jsonb_agg(jsonb_build_object('collectionId', it.collection_id, 'collectionName', c.collection_name,
           'name', it.name, 'imageUrl', it.image_url, 'rarity', case when coalesce(it.tag,'') = 'SSR' then 'SSR' else 'Normal' end)
           order by c.collection_name, it.id), '[]'::jsonb)
    from public.items it join public.collections c on c.collection_id = it.collection_id
   where c.category = 'Coaster' and c.collection_id not ilike 'gacha_npt%'
$$;

create or replace function public.create_coaster_trade(p_username text, p_inventory_id bigint, p_want jsonb) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare
  v_st jsonb;
  v_wc text := public.wallet_code_of(p_username);
  inv public.inventory;
  v_rarity text;
  v_want jsonb := '[]'::jsonb;
  w jsonb;
  v_id bigint;
begin
  perform 1 from public.users where username = p_username for update;
  v_st := public._coaster_trade_status(p_username);
  if not (v_st->>'eligible')::boolean then return jsonb_build_object('status','fail','message', v_st->>'reason'); end if;
  if (v_st->>'usedToday')::int >= 3 then return jsonb_build_object('status','fail','message','You have used all 3 trades for today. Come back tomorrow.'); end if;
  if (v_st->>'openCount')::int >= 5 then return jsonb_build_object('status','fail','message','You can have up to 5 open listings at a time.'); end if;

  select * into inv from public.inventory where id = p_inventory_id and wallet_code = v_wc and item_type = 'Coaster' for update;
  if not found then return jsonb_build_object('status','fail','message','This Coaster is not in your Inventory.'); end if;
  v_rarity := public._coaster_rarity(inv.collection_id, inv.item_name);
  if v_rarity is null then return jsonb_build_object('status','fail','message','This Coaster cannot be traded.'); end if;

  if p_want is not null and jsonb_typeof(p_want) = 'array' then
    if jsonb_array_length(p_want) > 3 then return jsonb_build_object('status','fail','message','You can choose up to 3 wanted Coasters.'); end if;
    for w in select * from jsonb_array_elements(p_want) loop
      if public._coaster_rarity(w->>'collectionId', w->>'name') is distinct from v_rarity then
        return jsonb_build_object('status','fail','message','Wanted Coasters must be the same rarity as yours.');
      end if;
      if w->>'collectionId' = inv.collection_id and w->>'name' = inv.item_name then
        return jsonb_build_object('status','fail','message','You cannot want the same Coaster you are offering.');
      end if;
      if not v_want @> jsonb_build_array(jsonb_build_object('collectionId', w->>'collectionId', 'name', w->>'name')) then
        v_want := v_want || jsonb_build_array(jsonb_build_object('collectionId', w->>'collectionId', 'name', w->>'name'));
      end if;
    end loop;
  end if;

  delete from public.inventory where id = inv.id;
  insert into public.coaster_trades (owner_wallet, offer_collection_id, offer_item_name, offer_image_url, offer_file_url, rarity, want)
    values (v_wc, inv.collection_id, inv.item_name, inv.image_url, inv.file_url, v_rarity, v_want)
    returning id into v_id;
  return jsonb_build_object('status','success','id', v_id);
end;
$$;

create or replace function public.cancel_coaster_trade(p_username text, p_trade_id bigint) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare
  v_wc text := public.wallet_code_of(p_username);
  t public.coaster_trades;
begin
  select * into t from public.coaster_trades where id = p_trade_id and owner_wallet = v_wc for update;
  if not found then return jsonb_build_object('status','fail','message','Listing not found.'); end if;
  if t.status <> 'open' then return jsonb_build_object('status','fail','message','This listing is already closed.'); end if;
  update public.coaster_trades set status = 'cancelled', cancelled_at = now() where id = t.id;
  insert into public.inventory (wallet_code, item_type, collection_id, item_name, image_url, file_url)
    values (v_wc, 'Coaster', t.offer_collection_id, t.offer_item_name, t.offer_image_url, t.offer_file_url);
  return jsonb_build_object('status','success');
end;
$$;

create or replace function public.accept_coaster_trade(p_username text, p_trade_id bigint, p_inventory_id bigint) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare
  v_st jsonb;
  v_wc text := public.wallet_code_of(p_username);
  t public.coaster_trades;
  inv public.inventory;
  v_owner_user text;
  v_taker_name text;
begin
  perform 1 from public.users where username = p_username for update;
  v_st := public._coaster_trade_status(p_username);
  if not (v_st->>'eligible')::boolean then return jsonb_build_object('status','fail','message', v_st->>'reason'); end if;
  if (v_st->>'usedToday')::int >= 3 then return jsonb_build_object('status','fail','message','You have used all 3 trades for today. Come back tomorrow.'); end if;

  select * into t from public.coaster_trades where id = p_trade_id for update;
  if not found or t.status <> 'open' then return jsonb_build_object('status','fail','message','This listing was already traded or cancelled.'); end if;
  if t.owner_wallet = v_wc then return jsonb_build_object('status','fail','message','You cannot trade with your own listing.'); end if;

  select * into inv from public.inventory where id = p_inventory_id and wallet_code = v_wc and item_type = 'Coaster' for update;
  if not found then return jsonb_build_object('status','fail','message','This Coaster is not in your Inventory.'); end if;
  if public._coaster_rarity(inv.collection_id, inv.item_name) is distinct from t.rarity then
    return jsonb_build_object('status','fail','message','You must use a Coaster of the same rarity.');
  end if;
  if jsonb_array_length(t.want) > 0
     and not t.want @> jsonb_build_array(jsonb_build_object('collectionId', inv.collection_id, 'name', inv.item_name)) then
    return jsonb_build_object('status','fail','message','This is not a Coaster the owner wants.');
  end if;

  -- swap: taker's coaster → owner, listed coaster → taker
  update public.inventory set wallet_code = t.owner_wallet, created_at = now() where id = inv.id;
  insert into public.inventory (wallet_code, item_type, collection_id, item_name, image_url, file_url)
    values (v_wc, 'Coaster', t.offer_collection_id, t.offer_item_name, t.offer_image_url, t.offer_file_url);
  update public.coaster_trades set status = 'done', done_at = now(), taker_wallet = v_wc,
         taker_collection_id = inv.collection_id, taker_item_name = inv.item_name,
         taker_image_url = inv.image_url, taker_file_url = inv.file_url
   where id = t.id;

  select username into v_owner_user from public.user_wallets where wallet_code = t.owner_wallet;
  select coalesce(name, username) into v_taker_name from public.users where username = p_username;
  if v_owner_user is not null then
    insert into public.notifications (writer, action, avatar, role, recipient_username, notif_type)
      values ('BLM48', 'Trade complete! ' || v_taker_name || ' traded ' || inv.item_name || ' for your ' || t.offer_item_name
                       || '. Check your Inventory.', inv.image_url, 'Admin', v_owner_user, 'trade');
  end if;
  return jsonb_build_object('status','success','received', jsonb_build_object('name', t.offer_item_name, 'imageUrl', t.offer_image_url));
end;
$$;

-- my listings + trades (open, done, cancelled), newest first
create or replace function public.get_my_coaster_trades(p_username text) returns jsonb
language sql stable security definer set search_path to 'public' as $$
  select coalesce(jsonb_agg(public._coaster_trade_json(t, w.wc) order by coalesce(t.done_at, t.cancelled_at, t.created_at) desc), '[]'::jsonb)
    from (select public.wallet_code_of(p_username) wc) w
    join public.coaster_trades t on t.owner_wallet = w.wc or t.taker_wallet = w.wc
$$;

revoke execute on function public._coaster_rarity(text,text) from public, anon, authenticated;
revoke execute on function public._coaster_trade_status(text) from public, anon, authenticated;
revoke execute on function public._coaster_trade_json(public.coaster_trades,text) from public, anon, authenticated;

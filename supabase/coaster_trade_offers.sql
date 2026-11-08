-- 🔁 Coaster Trade → offers the poster approves (2026-11-08, migration coaster_trade_offers)
-- User: instant swaps were unfair to the poster ("any"/3 wanted = the taker picks what the poster gets).
-- Now other fans send an OFFER (one per listing per fan); their Coaster is held (removed from inventory)
-- while the offer is pending. The poster sees every offer and accepts one (swap) or declines.
-- Accepting returns every other pending offer on that listing; cancelling the listing returns all of them.
-- Quota (3/day): posting a listing or sending an offer each uses 1; cancelled listings and
-- withdrawn/declined/returned offers give it back. Max 5 pending offers per fan.
-- Notifications (notif_type 'trade', sender BLM48): poster on new offer; offerer on accepted/declined/returned.
-- accept_coaster_trade (instant swap) is dropped.

create table if not exists public.coaster_trade_offers (
  id bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  trade_id bigint not null references public.coaster_trades(id),
  offerer_wallet text not null,
  collection_id text not null,
  item_name text not null,
  image_url text,
  file_url text,
  status text not null default 'pending' check (status in ('pending','accepted','declined','withdrawn','returned')),
  closed_at timestamptz
);
create index if not exists coaster_trade_offers_trade_idx on public.coaster_trade_offers (trade_id, status);
create index if not exists coaster_trade_offers_offerer_idx on public.coaster_trade_offers (offerer_wallet, created_at desc);
create unique index if not exists coaster_trade_offers_one_pending on public.coaster_trade_offers (trade_id, offerer_wallet) where status = 'pending';
alter table public.coaster_trade_offers enable row level security;
grant select, insert, update, delete on public.coaster_trade_offers to service_role;

drop function if exists public.accept_coaster_trade(text, bigint, bigint);

create or replace function public._coaster_trade_status(p_username text) returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare
  v_wc text := public.wallet_code_of(p_username);
  v_created timestamptz;
  v_status text;
  v_today date := (now() at time zone 'Asia/Bangkok')::date;
  v_used int;
  v_open int;
  v_offers int;
  v_reason text;
begin
  select status into v_status from public.users where username = p_username;
  select created_at into v_created from public.user_wallets where username = p_username;
  select (select count(*) from public.coaster_trades t
           where t.owner_wallet = v_wc and t.status <> 'cancelled' and (t.created_at at time zone 'Asia/Bangkok')::date = v_today)
       + (select count(*) from public.coaster_trade_offers o
           where o.offerer_wallet = v_wc and o.status in ('pending','accepted') and (o.created_at at time zone 'Asia/Bangkok')::date = v_today)
       -- instant swaps from before offers existed
       + (select count(*) from public.coaster_trades t
           where t.taker_wallet = v_wc and (t.done_at at time zone 'Asia/Bangkok')::date = v_today
             and not exists (select 1 from public.coaster_trade_offers o where o.trade_id = t.id and o.status = 'accepted'))
    into v_used;
  select count(*) into v_open from public.coaster_trades where owner_wallet = v_wc and status = 'open';
  select count(*) into v_offers from public.coaster_trade_offers where offerer_wallet = v_wc and status = 'pending';
  if v_wc is null or v_status is null then v_reason := 'Account not found';
  elsif v_status <> 'active' then v_reason := 'This account cannot use trading';
  elsif v_created is null or v_created > now() - interval '14 days' then
    v_reason := 'Trading unlocks when your account is 14 days old (' ||
      to_char((coalesce(v_created, now()) + interval '14 days') at time zone 'Asia/Bangkok', 'DD/MM/YYYY') || ')';
  end if;
  return jsonb_build_object('walletCode', v_wc, 'eligible', v_reason is null, 'reason', v_reason,
    'usedToday', v_used, 'dailyLimit', 3, 'openCount', v_open, 'maxOpen', 5, 'pendingOffers', v_offers, 'maxOffers', 5);
end;
$$;

create or replace function public._coaster_offer_json(o public.coaster_trade_offers) returns jsonb
language sql stable security definer set search_path to 'public' as $$
  select jsonb_build_object('id', o.id, 'tradeId', o.trade_id, 'status', o.status, 'createdAt', o.created_at, 'closedAt', o.closed_at,
    'item', jsonb_build_object('collectionId', o.collection_id, 'collectionName', c.collection_name, 'name', o.item_name, 'imageUrl', o.image_url),
    'offerer', jsonb_build_object('username', u.username, 'name', coalesce(u.name, u.username), 'img', u.profile_img))
  from (select 1) x
  left join public.collections c on c.collection_id = o.collection_id
  left join public.user_wallets w on w.wallet_code = o.offerer_wallet
  left join public.users u on u.username = w.username
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
    'doneAt', t.done_at,
    'offerCount', (select count(*) from public.coaster_trade_offers o where o.trade_id = t.id and o.status = 'pending'),
    -- poster sees every pending offer; everyone else only their own pending one
    'offers', case when t.owner_wallet = p_wc then coalesce((select jsonb_agg(public._coaster_offer_json(o) order by o.created_at)
                  from public.coaster_trade_offers o where o.trade_id = t.id and o.status = 'pending'), '[]'::jsonb) else '[]'::jsonb end,
    'myOffer', (select public._coaster_offer_json(o) from public.coaster_trade_offers o
                 where o.trade_id = t.id and o.offerer_wallet = p_wc and o.status = 'pending' limit 1))
  from (select 1) x
  left join public.collections oc on oc.collection_id = t.offer_collection_id
  left join public.user_wallets ow on ow.wallet_code = t.owner_wallet
  left join public.users ou on ou.username = ow.username
  left join public.user_wallets tw on tw.wallet_code = t.taker_wallet
  left join public.users tu on tu.username = tw.username
$$;

-- give a held offer Coaster back to its offerer and tell them why
create or replace function public._coaster_offer_return(o public.coaster_trade_offers, p_status text, p_msg text) returns void
language plpgsql security definer set search_path to 'public' as $$
declare v_user text;
begin
  update public.coaster_trade_offers set status = p_status, closed_at = now() where id = o.id;
  insert into public.inventory (wallet_code, item_type, collection_id, item_name, image_url, file_url)
    values (o.offerer_wallet, 'Coaster', o.collection_id, o.item_name, o.image_url, o.file_url);
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

  select * into inv from public.inventory where id = p_inventory_id and wallet_code = v_wc and item_type = 'Coaster' for update;
  if not found then return jsonb_build_object('status','fail','message','This Coaster is not in your Inventory.'); end if;
  if public._coaster_rarity(inv.collection_id, inv.item_name) is distinct from t.rarity then
    return jsonb_build_object('status','fail','message','You must use a Coaster of the same rarity.');
  end if;
  if inv.collection_id = t.offer_collection_id and inv.item_name = t.offer_item_name then
    return jsonb_build_object('status','fail','message','You cannot offer the same Coaster as the listing.');
  end if;
  if jsonb_array_length(t.want) > 0
     and not t.want @> jsonb_build_array(jsonb_build_object('collectionId', inv.collection_id, 'name', inv.item_name)) then
    return jsonb_build_object('status','fail','message','This is not a Coaster the owner wants.');
  end if;

  delete from public.inventory where id = inv.id;
  insert into public.coaster_trade_offers (trade_id, offerer_wallet, collection_id, item_name, image_url, file_url)
    values (t.id, v_wc, inv.collection_id, inv.item_name, inv.image_url, inv.file_url) returning id into v_id;

  select username into v_owner_user from public.user_wallets where wallet_code = t.owner_wallet;
  select coalesce(name, username) into v_name from public.users where username = p_username;
  if v_owner_user is not null then
    insert into public.notifications (writer, action, avatar, role, recipient_username, notif_type)
      values ('BLM48', 'New trade offer: ' || v_name || ' offers ' || inv.item_name || ' for your ' || t.offer_item_name
                       || '. Open Coaster Trade to accept or decline.', inv.image_url, 'Admin', v_owner_user, 'trade');
  end if;
  return jsonb_build_object('status','success','id', v_id);
end;
$$;

create or replace function public.withdraw_coaster_offer(p_username text, p_offer_id bigint) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare
  v_wc text := public.wallet_code_of(p_username);
  o public.coaster_trade_offers;
begin
  select * into o from public.coaster_trade_offers where id = p_offer_id and offerer_wallet = v_wc;
  if not found then return jsonb_build_object('status','fail','message','Offer not found.'); end if;
  perform 1 from public.coaster_trades where id = o.trade_id for update;   -- same lock order as accept
  select * into o from public.coaster_trade_offers where id = p_offer_id for update;
  if o.status <> 'pending' then return jsonb_build_object('status','fail','message','This offer is already closed.'); end if;
  perform public._coaster_offer_return(o, 'withdrawn', null);
  return jsonb_build_object('status','success');
end;
$$;

create or replace function public.decline_coaster_offer(p_username text, p_offer_id bigint) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare
  v_wc text := public.wallet_code_of(p_username);
  o public.coaster_trade_offers;
  t public.coaster_trades;
begin
  select * into o from public.coaster_trade_offers where id = p_offer_id;
  if not found then return jsonb_build_object('status','fail','message','Offer not found.'); end if;
  select * into t from public.coaster_trades where id = o.trade_id and owner_wallet = v_wc for update;
  if not found then return jsonb_build_object('status','fail','message','Offer not found.'); end if;
  select * into o from public.coaster_trade_offers where id = p_offer_id for update;
  if o.status <> 'pending' then return jsonb_build_object('status','fail','message','This offer is already closed.'); end if;
  perform public._coaster_offer_return(o, 'declined',
    'Your trade offer for ' || t.offer_item_name || ' was declined. ' || o.item_name || ' is back in your Inventory.');
  return jsonb_build_object('status','success');
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

  -- swap: offer Coaster → poster, listed Coaster → offerer
  insert into public.inventory (wallet_code, item_type, collection_id, item_name, image_url, file_url)
    values (t.owner_wallet, 'Coaster', o.collection_id, o.item_name, o.image_url, o.file_url),
           (o.offerer_wallet, 'Coaster', t.offer_collection_id, t.offer_item_name, t.offer_image_url, t.offer_file_url);
  update public.coaster_trade_offers set status = 'accepted', closed_at = now() where id = o.id;
  update public.coaster_trades set status = 'done', done_at = now(), taker_wallet = o.offerer_wallet,
         taker_collection_id = o.collection_id, taker_item_name = o.item_name,
         taker_image_url = o.image_url, taker_file_url = o.file_url
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
    values (v_wc, 'Coaster', t.offer_collection_id, t.offer_item_name, t.offer_image_url, t.offer_file_url);
  for r in select * from public.coaster_trade_offers where trade_id = t.id and status = 'pending' for update loop
    perform public._coaster_offer_return(r, 'returned',
      'The listing for ' || t.offer_item_name || ' was cancelled. ' || r.item_name || ' is back in your Inventory.');
  end loop;
  return jsonb_build_object('status','success');
end;
$$;

-- My Trades tab: my listings (any status) + offers I sent (any status), newest first
drop function if exists public.get_my_coaster_trades(text);
create or replace function public.get_my_coaster_trades(p_username text) returns jsonb
language sql stable security definer set search_path to 'public' as $$
  with w as (select public.wallet_code_of(p_username) wc)
  select jsonb_build_object(
    'listings', coalesce((select jsonb_agg(public._coaster_trade_json(t, w.wc) order by (t.status = 'open') desc, coalesce(t.done_at, t.cancelled_at, t.created_at) desc)
                            from public.coaster_trades t where t.owner_wallet = w.wc
                               or (t.taker_wallet = w.wc and not exists (select 1 from public.coaster_trade_offers o where o.trade_id = t.id))), '[]'::jsonb),
    'offers', coalesce((select jsonb_agg(public._coaster_offer_json(o) || jsonb_build_object('listing', public._coaster_trade_json(t, w.wc))
                                         order by (o.status = 'pending') desc, coalesce(o.closed_at, o.created_at) desc)
                          from public.coaster_trade_offers o join public.coaster_trades t on t.id = o.trade_id
                         where o.offerer_wallet = w.wc and o.status <> 'withdrawn'), '[]'::jsonb))
  from w
$$;

revoke execute on function public._coaster_trade_status(text) from public, anon, authenticated;
revoke execute on function public._coaster_offer_json(public.coaster_trade_offers) from public, anon, authenticated;
revoke execute on function public._coaster_trade_json(public.coaster_trades,text) from public, anon, authenticated;
revoke execute on function public._coaster_offer_return(public.coaster_trade_offers,text,text) from public, anon, authenticated;

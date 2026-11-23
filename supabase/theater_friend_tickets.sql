-- Theaters: buy a seat for a friend (2026-11-23)
-- A booker with 2+ seats can put a friend's Wallet Code on seat 2..n, at purchase or later
-- (until the Lucky Draw / end of show). That seat then:
--   * shows the friend's name on the ticket and appears in the friend's My Bookings
--   * Lucky Draw prize on that seat always goes to the friend (holder = name + wallet on the ticket)
--   * Official Souvenir + Ticket Stub + after-show souvenir of that seat go to the friend only
--     when the booker ticked "give items" (holder_gets_items); otherwise the booker keeps them.
-- Claims are tracked per ticket (*_claimed_at / *_claimed_by) so each side claims its own share.

-- 1) schema -------------------------------------------------------------------
alter table public.theater_bookings add column if not exists seat_rewards jsonb not null default '[]'::jsonb;

alter table public.theater_tickets
  add column if not exists holder_wallet_code text references public.user_wallets(wallet_code) on update cascade,
  add column if not exists holder_gets_items boolean not null default false,
  add column if not exists holder_set_at timestamptz,
  add column if not exists rewards_claimed_at timestamptz,
  add column if not exists rewards_claimed_by text,
  add column if not exists souvenirs_claimed_at timestamptz,
  add column if not exists souvenirs_claimed_by text,
  add column if not exists lucky_claimed_at timestamptz,
  add column if not exists lucky_claimed_by text;
create index if not exists theater_tickets_holder_idx on public.theater_tickets(holder_wallet_code) where holder_wallet_code is not null;

-- per-seat reward snapshot, derived from the expanded booking bundle
-- (items were repeated qty times in a row, amounts multiplied by qty)
update public.theater_bookings b set seat_rewards = coalesce((
  select jsonb_agg(case when x.v->>'kind' = 'item' then x.v
                        else x.v || jsonb_build_object('amount', coalesce((x.v->>'amount')::numeric,0) / b.quantity) end
                   order by x.o)
    from (select v, o, row_number() over (partition by (v->>'kind' = 'item') order by o) - 1 as k
            from jsonb_array_elements(b.rewards) with ordinality as a(v, o)) x
   where x.v->>'kind' <> 'item' or x.k % b.quantity = 0), '[]'::jsonb)
 where b.seat_rewards = '[]'::jsonb and jsonb_array_length(b.rewards) > 0;

-- carry booking-level claims down to the tickets
update public.theater_tickets t set rewards_claimed_at = b.rewards_redeemed_at, rewards_claimed_by = b.wallet_code
  from public.theater_bookings b where b.id = t.booking_id and b.rewards_redeemed_at is not null and t.rewards_claimed_at is null;
update public.theater_tickets t set souvenirs_claimed_at = b.souvenirs_claimed_at, souvenirs_claimed_by = b.wallet_code
  from public.theater_bookings b where b.id = t.booking_id and b.souvenirs_claimed_at is not null and t.souvenirs_claimed_at is null;
update public.theater_tickets t set lucky_claimed_at = b.lucky_claimed_at, lucky_claimed_by = b.wallet_code
  from public.theater_bookings b where b.id = t.booking_id and b.lucky_claimed_at is not null
   and t.lucky_won_at is not null and t.lucky_claimed_at is null;

-- 2) helpers ------------------------------------------------------------------
-- who receives this seat's items / lucky prize
create or replace function public.theater_items_to(t public.theater_tickets, p_booker text)
returns text language sql immutable as $$
  select case when t.holder_wallet_code is not null and t.holder_gets_items then t.holder_wallet_code else p_booker end
$$;
create or replace function public.theater_lucky_to(t public.theater_tickets, p_booker text)
returns text language sql immutable as $$
  select coalesce(t.holder_wallet_code, p_booker)
$$;

-- put a reward bundle into a wallet (items -> inventory, cookie/GE -> users + wallet_logs)
create or replace function public.theater_grant_bundle(p_wc text, p_rewards jsonb, p_default_type text,
                                                       p_collection text, p_log_action text, p_title text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_user text := public.username_of(p_wc);
  v_row jsonb;
  v_amount numeric;
begin
  perform 1 from public.users where username = v_user for update;
  for v_row in select * from jsonb_array_elements(coalesce(p_rewards,'[]'::jsonb)) loop
    v_amount := coalesce((v_row->>'amount')::numeric, 0);
    if v_row->>'kind' = 'item' then
      insert into public.inventory (wallet_code, item_type, collection_id, item_name, image_url)
        values (p_wc, coalesce(nullif(v_row->>'itemType',''), p_default_type), coalesce(v_row->>'collectionId', p_collection),
                v_row->>'label', v_row->>'imageUrl');
    elsif v_row->>'kind' = 'cookie' and v_amount > 0 then
      update public.users set cookie = cookie + v_amount, updated_at = now() where username = v_user;
      insert into public.wallet_logs (wallet_code, action, target, amount) values (p_wc, p_log_action, p_title || ' (Cookie)', v_amount);
    elsif v_row->>'kind' = 'ge_token' and v_amount > 0 then
      update public.users set ge_token = ge_token + v_amount, updated_at = now() where username = v_user;
      insert into public.wallet_logs (wallet_code, action, target, amount) values (p_wc, p_log_action, p_title || ' (GE Token)', v_amount);
    end if;
  end loop;
end $$;

-- resolve a friend's Wallet Code for a seat; returns {walletCode, username, name, profile_img} or {error}
create or replace function public.theater_resolve_friend(p_username text, p_wallet_code text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_code text := regexp_replace(coalesce(p_wallet_code,''), '[^0-9]', '', 'g');
  v_u record;
begin
  if v_code !~ '^[1-9][0-9]{9}$' then
    return jsonb_build_object('error','Wallet Code ไม่ถูกต้อง (BLM- ตามด้วยตัวเลข 10 หลัก)');
  end if;
  select u.username, u.name, u.profile_img, u.status into v_u
    from public.user_wallets w join public.users u on u.username = w.username where w.wallet_code = v_code;
  if not found then return jsonb_build_object('error','ไม่พบ Wallet Code นี้ในระบบ'); end if;
  if v_u.username = p_username then return jsonb_build_object('error','ใส่ Wallet Code ของตัวเองไม่ได้ ที่นั่งแรกเป็นของคุณอยู่แล้ว'); end if;
  if coalesce(v_u.status,'active') = 'suspended' then return jsonb_build_object('error','บัญชีนี้ถูกระงับการใช้งาน'); end if;
  return jsonb_build_object('walletCode', v_code, 'username', v_u.username, 'name', coalesce(v_u.name, v_u.username), 'profile_img', v_u.profile_img);
end $$;

create or replace function public.theater_lookup_friend(p_username text, p_wallet_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v jsonb := public.theater_resolve_friend(p_username, p_wallet_code);
begin
  if public.wallet_code_of(p_username) is null then return jsonb_build_object('status','error','message','ไม่พบบัญชีผู้ใช้ค่ะ'); end if;
  if v ? 'error' then return jsonb_build_object('status','error','message', v->>'error'); end if;
  return jsonb_build_object('status','success','data', v - 'username');
end $$;

-- assign one seat to a friend (shared by theater_book and theater_set_ticket_holder)
create or replace function public.theater_assign_holder(p_booking_id bigint, p_idx int, p_friend jsonb, p_give boolean)
returns void language plpgsql security definer set search_path = public as $$
declare
  b public.theater_bookings;
  e public.theater_events;
  v_buyer text;
begin
  select * into b from public.theater_bookings where id = p_booking_id;
  select * into e from public.theater_events where id = b.event_id;
  update public.theater_tickets set holder_wallet_code = p_friend->>'walletCode', holder_gets_items = coalesce(p_give,false),
         holder_set_at = now()
   where booking_id = p_booking_id and idx = p_idx;
  select coalesce(u.name, u.username) into v_buyer from public.users u where u.username = public.username_of(b.wallet_code);
  insert into public.notifications (writer, action, avatar, role, recipient_username, notif_type)
  values ('BLM48', coalesce(v_buyer,'เพื่อนของคุณ') || ' ซื้อบัตร ' || e.title || ' ให้คุณ 1 ที่นั่ง'
                   || case when coalesce(p_give,false) then ' พร้อมของที่ระลึก' else '' end
                   || ' ดูบัตรได้ที่ My Bookings', e.cover_url, 'Admin', p_friend->>'username', 'theater');
end $$;

-- 3) booking --------------------------------------------------------------------
drop function if exists public.theater_book(text, bigint, bigint, integer);
create or replace function public.theater_book(p_username text, p_round_id bigint, p_zone_id bigint, p_quantity integer,
                                               p_friends jsonb default '[]'::jsonb)
returns jsonb language plpgsql security definer set search_path = public as $function$
declare
  v_user record;
  v_round public.theater_rounds;
  v_e public.theater_events;
  v_zone public.theater_zones;
  v_wc text := public.wallet_code_of(p_username);
  v_left int;
  v_total numeric;
  v_new_token numeric;
  v_booking_id bigint;
  v_rewards jsonb := '[]'::jsonb;
  v_row jsonb;
  v_ids bigint[];
  v_friends jsonb := '[]'::jsonb;
  v_f jsonb;
  v_r jsonb;
  v_idx int;
  i int;
begin
  if p_username is null or v_wc is null then
    return jsonb_build_object('status','fail','message','ไม่พบบัญชีผู้ใช้ค่ะ');
  end if;
  select * into v_round from public.theater_rounds where id = p_round_id;
  if not found then return jsonb_build_object('status','fail','message','ไม่พบรอบการขายนี้ค่ะ'); end if;
  select * into v_e from public.theater_events where id = v_round.event_id;
  if v_e.status <> 'published' then
    return jsonb_build_object('status','fail','message','การแสดงนี้ไม่เปิดขายแล้วค่ะ');
  end if;
  if now() < v_round.open_at then
    return jsonb_build_object('status','fail','message','รอบนี้ยังไม่เปิดขายค่ะ');
  end if;
  if now() >= v_round.close_at then
    return jsonb_build_object('status','fail','message','รอบนี้ปิดการขายแล้วค่ะ (Booking Closed)');
  end if;
  if p_quantity is null or p_quantity < 1 or p_quantity > v_e.max_per_user then
    return jsonb_build_object('status','fail','message','จำกัด ' || v_e.max_per_user || ' ที่นั่งต่อ 1 บัญชีค่ะ');
  end if;

  -- friends: [{idx, walletCode, giveItems}] for seats 2..qty
  for v_f in select * from jsonb_array_elements(coalesce(p_friends,'[]'::jsonb)) loop
    if coalesce(v_f->>'walletCode','') = '' then continue; end if;
    v_idx := (v_f->>'idx')::int;
    if v_idx is null or v_idx < 2 or v_idx > p_quantity then
      return jsonb_build_object('status','fail','message','ที่นั่งแรกเป็นของผู้ซื้อ ใส่ Wallet เพื่อนได้ตั้งแต่ที่นั่งที่ 2 ค่ะ');
    end if;
    v_r := public.theater_resolve_friend(p_username, v_f->>'walletCode');
    if v_r ? 'error' then return jsonb_build_object('status','fail','message','ที่นั่ง ' || v_idx || ': ' || (v_r->>'error')); end if;
    if exists (select 1 from jsonb_array_elements(v_friends) x where (x->>'idx')::int = v_idx or x->>'walletCode' = v_r->>'walletCode') then
      return jsonb_build_object('status','fail','message','ใส่ Wallet Code ซ้ำกันไม่ได้ค่ะ');
    end if;
    v_friends := v_friends || jsonb_build_array(v_r || jsonb_build_object('idx', v_idx, 'give', coalesce((v_f->>'giveItems')::boolean, false)));
  end loop;

  select * into v_zone from public.theater_zones where id = p_zone_id and event_id = v_e.id for update;
  if not found then return jsonb_build_object('status','fail','message','ไม่พบโซนที่นั่งนี้ค่ะ'); end if;

  select * into v_user from public.users where username = p_username for update;
  if v_user.status = 'suspended' then
    return jsonb_build_object('status','fail','message','บัญชีนี้ถูกระงับการใช้งานค่ะ');
  end if;
  if exists (select 1 from public.theater_bookings where event_id = v_e.id and wallet_code = v_wc and status = 'paid') then
    return jsonb_build_object('status','fail','message','คุณจองการแสดงนี้ไปแล้วค่ะ ดูได้ที่ My Bookings', 'code','already_booked');
  end if;

  v_left := public.theater_zone_left(v_zone.id);
  if v_left < p_quantity then
    return jsonb_build_object('status','fail','message',
      case when v_left <= 0 then 'โซนนี้ที่นั่งเต็มแล้วค่ะ (Sold Out)' else 'โซนนี้เหลือเพียง ' || v_left || ' ที่นั่งค่ะ' end);
  end if;

  v_total := v_zone.price_tokens * p_quantity;
  if coalesce(v_user.token,0) < v_total then
    return jsonb_build_object('status','fail','message','Token ไม่เพียงพอค่ะ ต้องใช้ ' || v_total || ' Tokens');
  end if;

  for v_row in select * from jsonb_array_elements(v_zone.rewards) loop
    if v_row->>'kind' = 'item' then
      for i in 1..p_quantity loop v_rewards := v_rewards || jsonb_build_array(v_row); end loop;
    else
      v_rewards := v_rewards || jsonb_build_array(v_row || jsonb_build_object('amount', coalesce((v_row->>'amount')::numeric,0) * p_quantity));
    end if;
  end loop;

  update public.users set token = token - v_total, updated_at = now()
   where username = p_username returning token into v_new_token;

  insert into public.theater_bookings (booking_no, event_id, round_id, zone_id, wallet_code, quantity, unit_price, total_tokens, rewards, seat_rewards)
  values ('TT' || to_char(now() at time zone 'Asia/Bangkok','YYYY') || lpad(v_e.id::text, 4, '0') || '-'
            || upper(encode(extensions.gen_random_bytes(5),'hex')),
          v_e.id, v_round.id, v_zone.id, v_wc, p_quantity, v_zone.price_tokens, v_total, v_rewards, v_zone.rewards)
  returning id into v_booking_id;

  insert into public.theater_tickets (booking_id, idx, zone_id)
  select v_booking_id, g, v_zone.id from generate_series(1, p_quantity) g;

  for v_f in select * from jsonb_array_elements(v_friends) loop
    perform public.theater_assign_holder(v_booking_id, (v_f->>'idx')::int, v_f, (v_f->>'give')::boolean);
  end loop;

  if v_round.kind = 'express' then
    select array_agg(id) into v_ids from public.theater_tickets where booking_id = v_booking_id;
    perform public.theater_fill_seats(v_ids);
  end if;

  insert into public.wallet_logs (wallet_code, action, target, amount)
    values (v_wc, 'Buy Ticket', v_e.title || ' - ' || v_zone.name || ' x' || p_quantity, v_total);

  return jsonb_build_object('status','success','bookingId', v_booking_id, 'newToken', v_new_token);
end;
$function$;

-- add a friend to a seat after purchase (one time per seat, until Lucky Draw / end of show)
create or replace function public.theater_set_ticket_holder(p_username text, p_booking_id bigint, p_idx int,
                                                            p_wallet_code text, p_give_items boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  b public.theater_bookings;
  e public.theater_events;
  t public.theater_tickets;
  v_wc text := public.wallet_code_of(p_username);
  v_r jsonb;
begin
  select * into b from public.theater_bookings where id = p_booking_id and wallet_code = v_wc for update;
  if not found then return jsonb_build_object('status','fail','message','ไม่พบการจองนี้ค่ะ'); end if;
  if b.status <> 'paid' then return jsonb_build_object('status','fail','message','การจองนี้ถูกยกเลิกแล้วค่ะ'); end if;
  if b.source <> 'purchase' then return jsonb_build_object('status','fail','message','บัตรนี้มอบให้เพื่อนไม่ได้ค่ะ'); end if;
  select * into e from public.theater_events where id = b.event_id;
  if e.lucky_drawn_at is not null or now() >= public.theater_ended_at(e) then
    return jsonb_build_object('status','fail','message','หมดเวลาใส่ชื่อเพื่อนแล้วค่ะ (ประกาศผล Lucky Draw หรือจบการแสดงแล้ว)');
  end if;
  if p_idx is null or p_idx < 2 then
    return jsonb_build_object('status','fail','message','ที่นั่งแรกเป็นของผู้ซื้อค่ะ');
  end if;
  select * into t from public.theater_tickets where booking_id = b.id and idx = p_idx for update;
  if not found then return jsonb_build_object('status','fail','message','ไม่พบที่นั่งนี้ค่ะ'); end if;
  if t.holder_wallet_code is not null then
    return jsonb_build_object('status','fail','message','ที่นั่งนี้ใส่ชื่อเพื่อนไปแล้ว เปลี่ยนไม่ได้ค่ะ');
  end if;
  v_r := public.theater_resolve_friend(p_username, p_wallet_code);
  if v_r ? 'error' then return jsonb_build_object('status','fail','message', v_r->>'error'); end if;
  if exists (select 1 from public.theater_tickets where booking_id = b.id and holder_wallet_code = v_r->>'walletCode') then
    return jsonb_build_object('status','fail','message','เพื่อนคนนี้ได้ที่นั่งอื่นในการจองนี้แล้วค่ะ');
  end if;
  perform public.theater_assign_holder(b.id, p_idx, v_r, p_give_items);
  return jsonb_build_object('status','success');
end $$;

-- 4) read -----------------------------------------------------------------------
drop function if exists public.theater_booking_json(bigint, boolean);
create or replace function public.theater_booking_json(p_booking_id bigint, p_full boolean, p_viewer_wc text default null)
returns jsonb language plpgsql stable security definer set search_path = public as $function$
declare
  b public.theater_bookings;
  e public.theater_events;
  z public.theater_zones;
  r public.theater_rounds;
  v_me text;
  v_owner boolean;
  v_unseated int;
  v_issued boolean;
  v_tab text;
  v_qty int;
  v_items int;
  v_items_open int;
  v_souv int;
  v_souv_open int;
  v_buyer text;
  v_j jsonb;
begin
  select * into b from public.theater_bookings where id = p_booking_id;
  select * into e from public.theater_events where id = b.event_id;
  select * into z from public.theater_zones where id = b.zone_id;
  select * into r from public.theater_rounds where id = b.round_id;
  v_me := coalesce(p_viewer_wc, b.wallet_code);
  v_owner := v_me = b.wallet_code;
  select count(*) into v_unseated from public.theater_tickets where booking_id = b.id and seat_no is null;
  v_issued := b.status = 'paid' and v_unseated = 0;
  v_tab := case when b.status = 'cancelled' then 'cancelled'
                when e.event_date < public.theater_today() then 'past' else 'current' end;
  select count(*) into v_qty from public.theater_tickets t
   where t.booking_id = b.id and (v_owner or t.holder_wallet_code = v_me);
  select coalesce(u.name, u.username) into v_buyer from public.users u where u.username = public.username_of(b.wallet_code);
  v_j := jsonb_build_object(
    'id', b.id, 'bookingNo', b.booking_no, 'source', b.source, 'status', b.status, 'tab', v_tab,
    'role', case when v_owner then 'owner' else 'friend' end, 'buyerName', v_buyer,
    'quantity', v_qty, 'bookedQuantity', b.quantity, 'unitPrice', b.unit_price,
    'total', case when v_owner then b.total_tokens end,
    'createdAt', b.created_at, 'cancelledAt', b.cancelled_at, 'cancelReason', b.cancel_reason,
    'roundKind', r.kind, 'seatDrawAt', case when r.kind = 'normal' then r.close_at end,
    'zoneName', z.name, 'ticketIssued', v_issued,
    'giftCount', (select count(*) from public.theater_tickets t where t.booking_id = b.id and t.holder_wallet_code is not null),
    'event', jsonb_build_object('id', e.id, 'title', e.title, 'coverUrl', e.cover_url,
       'eventDate', e.event_date, 'startTime', to_char(e.start_time,'HH24:MI'),
       'endTime', to_char(e.end_time,'HH24:MI'), 'platform', e.platform, 'venue', e.venue));
  if p_full then
    -- seats whose items are mine: already claimed by me, or still open and routed to me
    select count(*) filter (where t.rewards_claimed_by = v_me or (t.rewards_claimed_at is null and public.theater_items_to(t, b.wallet_code) = v_me)),
           count(*) filter (where t.rewards_claimed_at is null and public.theater_items_to(t, b.wallet_code) = v_me),
           count(*) filter (where t.souvenirs_claimed_by = v_me or (t.souvenirs_claimed_at is null and public.theater_items_to(t, b.wallet_code) = v_me)),
           count(*) filter (where t.souvenirs_claimed_at is null and public.theater_items_to(t, b.wallet_code) = v_me)
      into v_items, v_items_open, v_souv, v_souv_open
      from public.theater_tickets t where t.booking_id = b.id;
    v_j := v_j || jsonb_build_object(
      'itemSeats', v_items,
      'rewards', public.theater_expand_rewards(b.seat_rewards, v_items),
      'rewardsRedeemedAt', case when v_items > 0 and v_items_open = 0 then
          (select max(t.rewards_claimed_at) from public.theater_tickets t where t.booking_id = b.id and t.rewards_claimed_by = v_me) end,
      'souvenirSeats', v_souv,
      'souvenirs', public.theater_expand_rewards(e.souvenirs, v_souv),
      'souvenirsAt', public.theater_ended_at(e),
      'souvenirsClaimedAt', case when v_souv > 0 and v_souv_open = 0 then
          (select max(t.souvenirs_claimed_at) from public.theater_tickets t where t.booking_id = b.id and t.souvenirs_claimed_by = v_me) end,
      'canAssign', v_owner and b.status = 'paid' and b.source = 'purchase' and b.quantity > 1
                   and e.lucky_drawn_at is null and now() < public.theater_ended_at(e),
      'holders', coalesce((select jsonb_agg(jsonb_build_object(
          'idx', t.idx, 'isGift', t.holder_wallet_code is not null, 'walletCode', coalesce(t.holder_wallet_code, b.wallet_code),
          'name', coalesce(hu.name, hu.username), 'giveItems', t.holder_gets_items, 'isMine', coalesce(t.holder_wallet_code, b.wallet_code) = v_me)
          order by t.idx)
          from public.theater_tickets t
          left join public.user_wallets hw on hw.wallet_code = coalesce(t.holder_wallet_code, b.wallet_code)
          left join public.users hu on hu.username = hw.username
         where t.booking_id = b.id and (v_owner or t.holder_wallet_code = v_me)), '[]'::jsonb),
      'lucky', case when jsonb_array_length(e.lucky_prize) > 0 then jsonb_build_object(
          'prize', e.lucky_prize, 'winnerCount', e.lucky_winner_count, 'drawnAt', e.lucky_drawn_at,
          'claimedAt', case when exists (select 1 from public.theater_tickets t where t.booking_id = b.id and t.lucky_won_at is not null
                                            and public.theater_lucky_to(t, b.wallet_code) = v_me)
                             and not exists (select 1 from public.theater_tickets t where t.booking_id = b.id and t.lucky_won_at is not null
                                            and public.theater_lucky_to(t, b.wallet_code) = v_me and t.lucky_claimed_at is null)
                            then (select max(t.lucky_claimed_at) from public.theater_tickets t where t.booking_id = b.id and t.lucky_claimed_by = v_me) end,
          'wonSeats', coalesce((select jsonb_agg(public.theater_seat_label(z.seat_prefix, t.seat_no) order by t.idx)
                                  from public.theater_tickets t where t.booking_id = b.id and t.lucky_won_at is not null
                                   and public.theater_lucky_to(t, b.wallet_code) = v_me), '[]'::jsonb),
          'friendWonSeats', case when v_owner then coalesce((select jsonb_agg(public.theater_seat_label(z.seat_prefix, t.seat_no) order by t.idx)
                                  from public.theater_tickets t where t.booking_id = b.id and t.lucky_won_at is not null
                                   and t.holder_wallet_code is not null), '[]'::jsonb) else '[]'::jsonb end) end,
      'watchUrl', case when v_issued then e.watch_url end,
      'watchNote', case when v_issued then e.watch_note end,
      'tickets', case when v_issued then coalesce((select jsonb_agg(jsonb_build_object(
          'idx', t.idx, 'seat', public.theater_seat_label(z.seat_prefix, t.seat_no), 'code', t.ticket_code,
          'holderName', coalesce(hu.name, hu.username), 'isGift', t.holder_wallet_code is not null) order by t.idx)
          from public.theater_tickets t
          left join public.user_wallets hw on hw.wallet_code = coalesce(t.holder_wallet_code, b.wallet_code)
          left join public.users hu on hu.username = hw.username
         where t.booking_id = b.id and (v_owner or t.holder_wallet_code = v_me)), '[]'::jsonb) else '[]'::jsonb end);
  end if;
  return v_j;
end;
$function$;

create or replace function public.get_my_theater_bookings(p_username text)
returns jsonb language plpgsql security definer set search_path = public as $function$
declare
  v_wc text := public.wallet_code_of(p_username);
begin
  perform public.theater_grant_holder_tickets(p_username);
  perform public.theater_draw_due(null);
  return jsonb_build_object('status','success','bookings', coalesce((
    select jsonb_agg(public.theater_booking_json(b.id, false, v_wc) order by e.event_date, b.id desc)
      from public.theater_bookings b join public.theater_events e on e.id = b.event_id
     where b.wallet_code = v_wc
        or exists (select 1 from public.theater_tickets t where t.booking_id = b.id and t.holder_wallet_code = v_wc)), '[]'::jsonb));
end;
$function$;

create or replace function public.get_theater_booking(p_username text, p_booking_id bigint)
returns jsonb language plpgsql security definer set search_path = public as $function$
declare
  v_wc text := public.wallet_code_of(p_username);
  v_event_id bigint;
begin
  select b.event_id into v_event_id from public.theater_bookings b
   where b.id = p_booking_id
     and (b.wallet_code = v_wc or exists (select 1 from public.theater_tickets t where t.booking_id = b.id and t.holder_wallet_code = v_wc));
  if not found then return jsonb_build_object('status','fail','message','ไม่พบการจองนี้ค่ะ'); end if;
  perform public.theater_draw_due(v_event_id);
  return jsonb_build_object('status','success','booking', public.theater_booking_json(p_booking_id, true, v_wc));
end;
$function$;

-- 5) claims (per seat) ------------------------------------------------------------
create or replace function public.redeem_theater_rewards(p_username text, p_booking_id bigint)
returns jsonb language plpgsql security definer set search_path = public as $function$
declare
  b public.theater_bookings;
  e public.theater_events;
  z public.theater_zones;
  v_wc text := public.wallet_code_of(p_username);
  v_ids bigint[];
  v_t record;
  v_seat text;
begin
  perform public.theater_draw_due(null);
  select * into b from public.theater_bookings bk where bk.id = p_booking_id
     and (bk.wallet_code = v_wc or exists (select 1 from public.theater_tickets t where t.booking_id = bk.id and t.holder_wallet_code = v_wc))
   for update;
  if not found then return jsonb_build_object('status','fail','message','ไม่พบการจองนี้ค่ะ'); end if;
  if b.status <> 'paid' then return jsonb_build_object('status','fail','message','การจองนี้ถูกยกเลิกแล้วค่ะ'); end if;
  if exists (select 1 from public.theater_tickets where booking_id = b.id and seat_no is null) then
    return jsonb_build_object('status','fail','message','รอระบบสุ่มที่นั่งก่อน จึงจะรับของได้ค่ะ');
  end if;
  select array_agg(t.id order by t.idx) into v_ids from public.theater_tickets t
   where t.booking_id = b.id and t.rewards_claimed_at is null and public.theater_items_to(t, b.wallet_code) = v_wc;
  if v_ids is null then
    return jsonb_build_object('status','fail','message',
      case when exists (select 1 from public.theater_tickets t where t.booking_id = b.id and t.rewards_claimed_by = v_wc)
           then 'รับของรางวัลไปแล้วค่ะ' else 'ของรางวัลของบัตรนี้เป็นของเจ้าของบัตรค่ะ' end);
  end if;
  select * into e from public.theater_events where id = b.event_id;
  select * into z from public.theater_zones where id = b.zone_id;

  perform public.theater_grant_bundle(v_wc, public.theater_expand_rewards(b.seat_rewards, cardinality(v_ids)),
                                      'Merchandise Official', 'theater_' || e.id, 'Ticket Reward', e.title);
  for v_t in select * from public.theater_tickets where id = any(v_ids) order by idx loop
    v_seat := public.theater_seat_label(z.seat_prefix, v_t.seat_no);
    insert into public.inventory (wallet_code, item_type, collection_id, item_name, image_url)
      values (v_wc, 'Ticket Stub', 'theater_' || e.id,
              e.title || ' · ' || to_char(e.event_date,'DD Mon YYYY') || ' · Seat ' || v_seat,
              public.theater_ticket_image(e.id, v_seat));
  end loop;

  update public.theater_tickets set rewards_claimed_at = now(), rewards_claimed_by = v_wc where id = any(v_ids);
  if v_wc = b.wallet_code then update public.theater_bookings set rewards_redeemed_at = now() where id = b.id; end if;
  return jsonb_build_object('status','success',
    'wallet', (select jsonb_build_object('token', token, 'cookie', cookie, 'geToken', ge_token) from public.users where username = p_username));
end;
$function$;

create or replace function public.claim_theater_souvenirs(p_username text, p_booking_id bigint)
returns jsonb language plpgsql security definer set search_path = public as $function$
declare
  b public.theater_bookings;
  e public.theater_events;
  v_wc text := public.wallet_code_of(p_username);
  v_ids bigint[];
begin
  perform public.theater_draw_due(null);
  select * into b from public.theater_bookings bk where bk.id = p_booking_id
     and (bk.wallet_code = v_wc or exists (select 1 from public.theater_tickets t where t.booking_id = bk.id and t.holder_wallet_code = v_wc))
   for update;
  if not found then return jsonb_build_object('status','fail','message','ไม่พบการจองนี้ค่ะ'); end if;
  if b.status <> 'paid' then return jsonb_build_object('status','fail','message','การจองนี้ถูกยกเลิกแล้วค่ะ'); end if;
  if exists (select 1 from public.theater_tickets where booking_id = b.id and seat_no is null) then
    return jsonb_build_object('status','fail','message','รอระบบสุ่มที่นั่งก่อนค่ะ');
  end if;
  select * into e from public.theater_events where id = b.event_id;
  if now() < public.theater_ended_at(e) then
    return jsonb_build_object('status','fail','message','รับของที่ระลึกได้หลังจบการแสดงค่ะ');
  end if;
  if jsonb_array_length(coalesce(e.souvenirs,'[]'::jsonb)) = 0 then
    return jsonb_build_object('status','fail','message','การแสดงนี้ยังไม่มีของที่ระลึกค่ะ');
  end if;
  select array_agg(t.id) into v_ids from public.theater_tickets t
   where t.booking_id = b.id and t.souvenirs_claimed_at is null and public.theater_items_to(t, b.wallet_code) = v_wc;
  if v_ids is null then
    return jsonb_build_object('status','fail','message',
      case when exists (select 1 from public.theater_tickets t where t.booking_id = b.id and t.souvenirs_claimed_by = v_wc)
           then 'รับของที่ระลึกไปแล้วค่ะ' else 'ของที่ระลึกของบัตรนี้เป็นของเจ้าของบัตรค่ะ' end);
  end if;

  perform public.theater_grant_bundle(v_wc, public.theater_expand_rewards(e.souvenirs, cardinality(v_ids)),
                                      'Souvenir', 'theater_' || e.id, 'Theater Souvenir', e.title);
  update public.theater_tickets set souvenirs_claimed_at = now(), souvenirs_claimed_by = v_wc where id = any(v_ids);
  if v_wc = b.wallet_code then update public.theater_bookings set souvenirs_claimed_at = now() where id = b.id; end if;
  return jsonb_build_object('status','success',
    'wallet', (select jsonb_build_object('token', token, 'cookie', cookie, 'geToken', ge_token) from public.users where username = p_username));
end;
$function$;

-- Lucky Draw prize always goes to the seat's holder (the name + wallet on the ticket)
create or replace function public.claim_theater_lucky(p_username text, p_booking_id bigint)
returns jsonb language plpgsql security definer set search_path = public as $function$
declare
  b public.theater_bookings;
  e public.theater_events;
  v_wc text := public.wallet_code_of(p_username);
  v_ids bigint[];
begin
  select * into b from public.theater_bookings bk where bk.id = p_booking_id
     and (bk.wallet_code = v_wc or exists (select 1 from public.theater_tickets t where t.booking_id = bk.id and t.holder_wallet_code = v_wc))
   for update;
  if not found then return jsonb_build_object('status','fail','message','ไม่พบการจองนี้ค่ะ'); end if;
  if b.status <> 'paid' then return jsonb_build_object('status','fail','message','การจองนี้ถูกยกเลิกแล้วค่ะ'); end if;
  if not exists (select 1 from public.theater_tickets t where t.booking_id = b.id and t.lucky_won_at is not null
                    and public.theater_lucky_to(t, b.wallet_code) = v_wc) then
    return jsonb_build_object('status','fail','message','บัตรของคุณไม่ได้รับรางวัลค่ะ');
  end if;
  select array_agg(t.id) into v_ids from public.theater_tickets t
   where t.booking_id = b.id and t.lucky_won_at is not null and t.lucky_claimed_at is null
     and public.theater_lucky_to(t, b.wallet_code) = v_wc;
  if v_ids is null then return jsonb_build_object('status','fail','message','รับรางวัลไปแล้วค่ะ'); end if;
  select * into e from public.theater_events where id = b.event_id;

  perform public.theater_grant_bundle(v_wc, public.theater_expand_rewards(e.lucky_prize, cardinality(v_ids)),
                                      'SSR', 'theater_' || e.id, 'Theater Lucky Draw', e.title);
  update public.theater_tickets set lucky_claimed_at = now(), lucky_claimed_by = v_wc where id = any(v_ids);
  if v_wc = b.wallet_code then update public.theater_bookings set lucky_claimed_at = now() where id = b.id; end if;
  return jsonb_build_object('status','success',
    'wallet', (select jsonb_build_object('token', token, 'cookie', cookie, 'geToken', ge_token) from public.users where username = p_username));
end;
$function$;

-- 6) admin: winners / notifications / bookings show the seat holder -----------------
create or replace function public.theater_lucky_winners(p_event_id bigint)
returns jsonb language sql stable security definer set search_path = public as $function$
  select coalesce(jsonb_agg(jsonb_build_object(
      'bookingId', b.id, 'bookingNo', b.booking_no, 'username', w.username, 'name', u.name,
      'isGift', t.holder_wallet_code is not null, 'buyerName', bu.name,
      'zoneName', z.name, 'seat', public.theater_seat_label(z.seat_prefix, t.seat_no),
      'claimed', t.lucky_claimed_at is not null) order by t.lucky_won_at, t.id), '[]'::jsonb)
    from public.theater_tickets t
    join public.theater_bookings b on b.id = t.booking_id
    join public.theater_zones z on z.id = t.zone_id
    left join public.user_wallets w on w.wallet_code = coalesce(t.holder_wallet_code, b.wallet_code)
    left join public.users u on u.username = w.username
    left join public.user_wallets bw on bw.wallet_code = b.wallet_code
    left join public.users bu on bu.username = bw.username
   where b.event_id = p_event_id and t.lucky_won_at is not null
$function$;

do $$
declare v_def text;
begin
  -- winner notifications go to the seat holder
  v_def := pg_get_functiondef('public.admin_draw_theater_lucky(text,bigint)'::regprocedure);
  if position('coalesce(t.holder_wallet_code, b.wallet_code) as wallet_code' in v_def) = 0 then
    v_def := replace(v_def, 'select distinct b.wallet_code from public.theater_tickets t',
                            'select distinct coalesce(t.holder_wallet_code, b.wallet_code) as wallet_code from public.theater_tickets t');
    if position('coalesce(t.holder_wallet_code, b.wallet_code) as wallet_code' in v_def) = 0 then
      raise exception 'admin_draw_theater_lucky patch did not apply';
    end if;
    execute v_def;
  end if;

  -- admin bookings list: which seats were given to whom
  v_def := pg_get_functiondef('public.admin_get_theater_event(text,bigint)'::regprocedure);
  if position('''gifts''' in v_def) = 0 then
    v_def := replace(v_def, '''souvenirClaimed'', b.souvenirs_claimed_at is not null,',
      '''souvenirClaimed'', b.souvenirs_claimed_at is not null,
                 ''gifts'', (select jsonb_agg(jsonb_build_object(''idx'', t.idx, ''seat'', public.theater_seat_label(z.seat_prefix, t.seat_no),
                               ''name'', coalesce(gu.name, gu.username), ''giveItems'', t.holder_gets_items) order by t.idx)
                             from public.theater_tickets t
                             join public.user_wallets gw on gw.wallet_code = t.holder_wallet_code
                             join public.users gu on gu.username = gw.username
                            where t.booking_id = b.id),');
    if position('''gifts''' in v_def) = 0 then raise exception 'admin_get_theater_event patch did not apply'; end if;
    execute v_def;
  end if;
end $$;

-- 7) grants ---------------------------------------------------------------------
revoke all on function public.theater_items_to(public.theater_tickets, text) from public, anon, authenticated;
revoke all on function public.theater_lucky_to(public.theater_tickets, text) from public, anon, authenticated;
revoke all on function public.theater_grant_bundle(text, jsonb, text, text, text, text) from public, anon, authenticated;
revoke all on function public.theater_resolve_friend(text, text) from public, anon, authenticated;
revoke all on function public.theater_assign_holder(bigint, int, jsonb, boolean) from public, anon, authenticated;
revoke all on function public.theater_booking_json(bigint, boolean, text) from public, anon, authenticated;
grant execute on function public.theater_book(text, bigint, bigint, integer, jsonb) to anon, authenticated;
grant execute on function public.theater_set_ticket_holder(text, bigint, int, text, boolean) to anon, authenticated;
grant execute on function public.theater_lookup_friend(text, text) to anon, authenticated;

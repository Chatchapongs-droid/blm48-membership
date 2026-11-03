-- 🎁 Theater post-show souvenirs (2026-11-03, migration theater_souvenirs)
-- theater_events.souvenirs = event-wide reward list (same shape as theater_zones.rewards), given per seat
-- to every paid ticket holder once the show has ended (event_date + end_time, else end of that day, Bangkok).
-- Not snapshotted on the booking: admins can add/edit souvenirs any time (also after the show);
-- fans who already claimed keep what they got. Claim via claim_theater_souvenirs → Inventory.

alter table public.theater_events add column if not exists souvenirs jsonb not null default '[]'::jsonb;
alter table public.theater_bookings add column if not exists souvenirs_claimed_at timestamptz;

-- when the show is over (Bangkok time)
create or replace function public.theater_ended_at(e public.theater_events) returns timestamptz
language sql stable as $$
  select ((e.event_date + coalesce(e.end_time, time '23:59:59'))::timestamp at time zone 'Asia/Bangkok')
$$;

-- per-seat reward list x quantity (items repeated, amounts multiplied)
create or replace function public.theater_expand_rewards(p_rewards jsonb, p_qty int) returns jsonb
language plpgsql immutable as $$
declare
  v_out jsonb := '[]'::jsonb;
  v_row jsonb;
  i int;
begin
  for v_row in select * from jsonb_array_elements(coalesce(p_rewards,'[]'::jsonb)) loop
    if v_row->>'kind' = 'item' then
      for i in 1..p_qty loop v_out := v_out || jsonb_build_array(v_row); end loop;
    else
      v_out := v_out || jsonb_build_array(v_row || jsonb_build_object('amount', coalesce((v_row->>'amount')::numeric,0) * p_qty));
    end if;
  end loop;
  return v_out;
end;
$$;

create or replace function public.theater_booking_json(p_booking_id bigint, p_full boolean)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
declare
  b public.theater_bookings;
  e public.theater_events;
  z public.theater_zones;
  r public.theater_rounds;
  v_unseated int;
  v_issued boolean;
  v_tab text;
  v_j jsonb;
begin
  select * into b from public.theater_bookings where id = p_booking_id;
  select * into e from public.theater_events where id = b.event_id;
  select * into z from public.theater_zones where id = b.zone_id;
  select * into r from public.theater_rounds where id = b.round_id;
  select count(*) into v_unseated from public.theater_tickets where booking_id = b.id and seat_no is null;
  v_issued := b.status = 'paid' and v_unseated = 0;
  v_tab := case when b.status = 'cancelled' then 'cancelled'
                when e.event_date < public.theater_today() then 'past' else 'current' end;
  v_j := jsonb_build_object(
    'id', b.id, 'bookingNo', b.booking_no, 'source', b.source, 'status', b.status, 'tab', v_tab,
    'quantity', b.quantity, 'unitPrice', b.unit_price, 'total', b.total_tokens,
    'createdAt', b.created_at, 'cancelledAt', b.cancelled_at, 'cancelReason', b.cancel_reason,
    'roundKind', r.kind, 'seatDrawAt', case when r.kind = 'normal' then r.close_at end,
    'zoneName', z.name, 'ticketIssued', v_issued,
    'event', jsonb_build_object('id', e.id, 'title', e.title, 'coverUrl', e.cover_url,
       'eventDate', e.event_date, 'startTime', to_char(e.start_time,'HH24:MI'),
       'endTime', to_char(e.end_time,'HH24:MI'), 'platform', e.platform, 'venue', e.venue));
  if p_full then
    v_j := v_j || jsonb_build_object(
      'rewards', b.rewards, 'rewardsRedeemedAt', b.rewards_redeemed_at,
      'souvenirs', public.theater_expand_rewards(e.souvenirs, b.quantity),
      'souvenirsAt', public.theater_ended_at(e),
      'souvenirsClaimedAt', b.souvenirs_claimed_at,
      'watchUrl', case when v_issued then e.watch_url end,
      'watchNote', case when v_issued then e.watch_note end,
      'tickets', case when v_issued then coalesce((select jsonb_agg(jsonb_build_object(
          'idx', t.idx, 'seat', public.theater_seat_label(z.seat_prefix, t.seat_no), 'code', t.ticket_code) order by t.idx)
          from public.theater_tickets t where t.booking_id = b.id), '[]'::jsonb) else '[]'::jsonb end);
  end if;
  return v_j;
end;
$function$;

create or replace function public.claim_theater_souvenirs(p_username text, p_booking_id bigint) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare
  b public.theater_bookings;
  e public.theater_events;
  v_wc text := public.wallet_code_of(p_username);
  v_row jsonb;
  v_amount numeric;
begin
  perform public.theater_draw_due(null);
  select * into b from public.theater_bookings where id = p_booking_id and wallet_code = v_wc for update;
  if not found then return jsonb_build_object('status','fail','message','ไม่พบการจองนี้ค่ะ'); end if;
  if b.status <> 'paid' then return jsonb_build_object('status','fail','message','การจองนี้ถูกยกเลิกแล้วค่ะ'); end if;
  if b.souvenirs_claimed_at is not null then return jsonb_build_object('status','fail','message','รับของที่ระลึกไปแล้วค่ะ'); end if;
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
  perform 1 from public.users where username = p_username for update;

  for v_row in select * from jsonb_array_elements(public.theater_expand_rewards(e.souvenirs, b.quantity)) loop
    v_amount := coalesce((v_row->>'amount')::numeric, 0);
    if v_row->>'kind' = 'item' then
      insert into public.inventory (wallet_code, item_type, collection_id, item_name, image_url)
        values (v_wc, coalesce(nullif(v_row->>'itemType',''),'Souvenir'), coalesce(v_row->>'collectionId','theater_' || e.id),
                v_row->>'label', v_row->>'imageUrl');
    elsif v_row->>'kind' = 'cookie' and v_amount > 0 then
      update public.users set cookie = cookie + v_amount, updated_at = now() where username = p_username;
      insert into public.wallet_logs (wallet_code, action, target, amount) values (v_wc, 'Theater Souvenir', e.title || ' (Cookie)', v_amount);
    elsif v_row->>'kind' = 'ge_token' and v_amount > 0 then
      update public.users set ge_token = ge_token + v_amount, updated_at = now() where username = p_username;
      insert into public.wallet_logs (wallet_code, action, target, amount) values (v_wc, 'Theater Souvenir', e.title || ' (GE Token)', v_amount);
    end if;
  end loop;

  update public.theater_bookings set souvenirs_claimed_at = now() where id = b.id;
  return jsonb_build_object('status','success',
    'wallet', (select jsonb_build_object('token', token, 'cookie', cookie, 'geToken', ge_token) from public.users where username = p_username));
end;
$$;

create or replace function public.admin_get_theater_event(p_admin_username text, p_event_id bigint)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  e public.theater_events;
begin
  if not public.is_admin_or_ceo(p_admin_username) then
    return jsonb_build_object('status','error','message','ไม่มีสิทธิ์ทำรายการนี้');
  end if;
  perform public.theater_draw_due(p_event_id);
  select * into e from public.theater_events where id = p_event_id;
  if not found then return jsonb_build_object('status','error','message','ไม่พบการแสดงนี้'); end if;
  return jsonb_build_object('status','success','event', jsonb_build_object(
    'id', e.id, 'title', e.title, 'coverUrl', e.cover_url, 'seatmapUrl', e.seatmap_url, 'holderCollections', to_jsonb(e.holder_collections), 'eventDate', e.event_date,
    'startTime', to_char(e.start_time,'HH24:MI'), 'endTime', to_char(e.end_time,'HH24:MI'),
    'platform', e.platform, 'venue', e.venue, 'watchUrl', e.watch_url, 'watchNote', e.watch_note,
    'description', e.description, 'memberIds', to_jsonb(e.member_ids), 'maxPerUser', e.max_per_user,
    'status', e.status, 'cancelReason', e.cancel_reason,
    'souvenirs', e.souvenirs, 'endedAt', public.theater_ended_at(e),
    'rounds', coalesce((select jsonb_agg(public.theater_round_json(r) || jsonb_build_object('drawDone', r.draw_done) order by r.open_at)
                          from public.theater_rounds r where r.event_id = e.id), '[]'::jsonb),
    'zones', coalesce((select jsonb_agg(jsonb_build_object(
                 'id', z.id, 'name', z.name, 'note', z.note, 'price', z.price_tokens, 'capacity', z.capacity,
                 'seatPrefix', z.seat_prefix, 'rewards', z.rewards, 'left', public.theater_zone_left(z.id),
                 'hasBookings', exists (select 1 from public.theater_bookings b where b.zone_id = z.id))
                 order by z.sort_order, z.id)
               from public.theater_zones z where z.event_id = e.id), '[]'::jsonb),
    'bookings', coalesce((select jsonb_agg(jsonb_build_object(
                 'id', b.id, 'bookingNo', b.booking_no, 'source', b.source, 'username', w.username, 'name', u.name,
                 'zoneName', z.name, 'roundKind', r.kind, 'quantity', b.quantity, 'total', b.total_tokens,
                 'status', b.status, 'createdAt', b.created_at, 'redeemed', b.rewards_redeemed_at is not null,
                 'souvenirClaimed', b.souvenirs_claimed_at is not null,
                 'seats', (select jsonb_agg(public.theater_seat_label(z.seat_prefix, t.seat_no) order by t.idx)
                             from public.theater_tickets t where t.booking_id = b.id))
                 order by b.created_at desc)
               from public.theater_bookings b
               join public.theater_zones z on z.id = b.zone_id
               join public.theater_rounds r on r.id = b.round_id
               left join public.user_wallets w on w.wallet_code = b.wallet_code
               left join public.users u on u.username = w.username
              where b.event_id = e.id), '[]'::jsonb)
  ));
end;
$function$;

-- admin_save_theater_event: only change vs the live definition is the souvenirs line in the UPDATE
create or replace function public.admin_save_theater_event(p_admin_username text, p_event jsonb)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_id bigint := nullif(p_event->>'id','')::bigint;
  v_r jsonb;
  v_z jsonb;
  v_keep_rounds bigint[] := '{}';
  v_keep_zones bigint[] := '{}';
  v_rid bigint;
  v_zid bigint;
  v_sort int := 0;
begin
  if not public.is_admin_or_ceo(p_admin_username) then
    return jsonb_build_object('status','error','message','ไม่มีสิทธิ์ทำรายการนี้');
  end if;
  if coalesce(trim(p_event->>'title'),'') = '' or nullif(p_event->>'eventDate','') is null then
    return jsonb_build_object('status','error','message','กรุณากรอกชื่อการแสดงและวันที่แสดง');
  end if;
  if jsonb_array_length(coalesce(p_event->'zones','[]')) = 0 or jsonb_array_length(coalesce(p_event->'rounds','[]')) = 0 then
    return jsonb_build_object('status','error','message','ต้องมีอย่างน้อย 1 รอบขาย และ 1 โซนที่นั่ง');
  end if;
  if coalesce(p_event->>'status','draft') not in ('draft','published') then
    return jsonb_build_object('status','error','message','สถานะไม่ถูกต้อง');
  end if;

  if v_id is null then
    insert into public.theater_events (title, event_date, created_by)
      values (trim(p_event->>'title'), (p_event->>'eventDate')::date, p_admin_username) returning id into v_id;
  elsif not exists (select 1 from public.theater_events where id = v_id and status <> 'cancelled') then
    return jsonb_build_object('status','error','message','ไม่พบการแสดงนี้ หรือถูกยกเลิกไปแล้ว');
  end if;

  update public.theater_events set
    title = trim(p_event->>'title'),
    cover_url = nullif(trim(p_event->>'coverUrl'),''),
    seatmap_url = nullif(trim(p_event->>'seatmapUrl'),''),
    event_date = (p_event->>'eventDate')::date,
    start_time = nullif(p_event->>'startTime','')::time,
    end_time = nullif(p_event->>'endTime','')::time,
    platform = coalesce(nullif(p_event->>'platform',''),'youtube'),
    venue = nullif(trim(p_event->>'venue'),''),
    watch_url = nullif(trim(p_event->>'watchUrl'),''),
    watch_note = nullif(trim(p_event->>'watchNote'),''),
    description = nullif(p_event->>'description',''),
    member_ids = coalesce((select array_agg(x) from jsonb_array_elements_text(coalesce(p_event->'memberIds','[]')) x), '{}'),
    max_per_user = coalesce(nullif(p_event->>'maxPerUser','')::int, 2),
    status = coalesce(p_event->>'status','draft'),
    souvenirs = coalesce(p_event->'souvenirs','[]'::jsonb),
    updated_at = now()
  where id = v_id;

  for v_r in select * from jsonb_array_elements(p_event->'rounds') loop
    if (v_r->>'closeAt')::timestamptz <= (v_r->>'openAt')::timestamptz then
      raise exception 'เวลาปิดขายต้องหลังเวลาเปิดขาย';
    end if;
    v_rid := nullif(v_r->>'id','')::bigint;
    if v_rid is not null and exists (select 1 from public.theater_rounds where id = v_rid and event_id = v_id) then
      update public.theater_rounds set kind = v_r->>'kind', open_at = (v_r->>'openAt')::timestamptz,
             close_at = (v_r->>'closeAt')::timestamptz,
             draw_done = case when (v_r->>'closeAt')::timestamptz > now() then false else draw_done end
       where id = v_rid;
    else
      insert into public.theater_rounds (event_id, kind, open_at, close_at)
        values (v_id, v_r->>'kind', (v_r->>'openAt')::timestamptz, (v_r->>'closeAt')::timestamptz) returning id into v_rid;
    end if;
    v_keep_rounds := v_keep_rounds || v_rid;
  end loop;

  for v_z in select * from jsonb_array_elements(p_event->'zones') loop
    v_sort := v_sort + 1;
    v_zid := nullif(v_z->>'id','')::bigint;
    if v_zid is not null and exists (select 1 from public.theater_zones where id = v_zid and event_id = v_id) then
      if (v_z->>'capacity')::int < (select coalesce(sum(quantity),0) from public.theater_bookings where zone_id = v_zid and status = 'paid')
         or (v_z->>'capacity')::int < coalesce((select max(seat_no) from public.theater_tickets where zone_id = v_zid), 0) then
        raise exception 'โซน % มีคนจองมากกว่าจำนวนที่นั่งใหม่', v_z->>'name';
      end if;
      update public.theater_zones set name = trim(v_z->>'name'), note = nullif(trim(v_z->>'note'),''),
             price_tokens = (v_z->>'price')::numeric, capacity = (v_z->>'capacity')::int,
             seat_prefix = coalesce(nullif(trim(v_z->>'seatPrefix'),''),'A'),
             rewards = coalesce(v_z->'rewards','[]'), sort_order = v_sort
       where id = v_zid;
    else
      insert into public.theater_zones (event_id, name, note, price_tokens, capacity, seat_prefix, rewards, sort_order)
        values (v_id, trim(v_z->>'name'), nullif(trim(v_z->>'note'),''), (v_z->>'price')::numeric, (v_z->>'capacity')::int,
                coalesce(nullif(trim(v_z->>'seatPrefix'),''),'A'), coalesce(v_z->'rewards','[]'), v_sort)
        returning id into v_zid;
    end if;
    v_keep_zones := v_keep_zones || v_zid;
  end loop;

  if exists (select 1 from public.theater_bookings where event_id = v_id
              and (round_id <> all(v_keep_rounds) or zone_id <> all(v_keep_zones))) then
    raise exception 'ลบรอบหรือโซนที่มีคนจองแล้วไม่ได้';
  end if;
  delete from public.theater_rounds where event_id = v_id and id <> all(v_keep_rounds);
  delete from public.theater_zones where event_id = v_id and id <> all(v_keep_zones);

  return jsonb_build_object('status','success','id', v_id);
exception when others then
  return jsonb_build_object('status','error','message', sqlerrm);
end;
$function$;

revoke execute on function public.theater_expand_rewards(jsonb, int) from public, anon, authenticated;

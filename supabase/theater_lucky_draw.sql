-- 🍀 Theater Lucky Draw (2026-11-03, migration theater_lucky_draw)
-- theater_events.lucky_prize = reward list (same shape as zone rewards, e.g. the one-of-a-kind SSR card)
-- given to lucky_winner_count random tickets (1 seat = 1 chance) among paid ticket holders.
-- Admin presses "สุ่มผู้โชคดี" on admin_theater_event once every sales round has closed
-- (admin_draw_theater_lucky); the result is permanent (one draw per event). Winners get a 'theater'
-- notification and claim the prize on Booking Detail (claim_theater_lucky → Inventory).
-- Prize/count can be edited until the draw, then admin_save_theater_event leaves them untouched.

alter table public.theater_events add column if not exists lucky_prize jsonb not null default '[]'::jsonb;
alter table public.theater_events add column if not exists lucky_winner_count int not null default 1 check (lucky_winner_count between 1 and 100);
alter table public.theater_events add column if not exists lucky_drawn_at timestamptz;
alter table public.theater_events add column if not exists lucky_drawn_by text;
alter table public.theater_tickets add column if not exists lucky_won_at timestamptz;
alter table public.theater_bookings add column if not exists lucky_claimed_at timestamptz;

alter table public.notifications drop constraint notifications_notif_type_check;
alter table public.notifications add constraint notifications_notif_type_check
  check (notif_type = any (array['post','comment','reply','mention','admin','shop','wallet','preorder','theater']));

-- winners list for the admin page
create or replace function public.theater_lucky_winners(p_event_id bigint) returns jsonb
language sql stable security definer set search_path to 'public' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
      'bookingId', b.id, 'bookingNo', b.booking_no, 'username', w.username, 'name', u.name,
      'zoneName', z.name, 'seat', public.theater_seat_label(z.seat_prefix, t.seat_no),
      'claimed', b.lucky_claimed_at is not null) order by t.lucky_won_at, t.id), '[]'::jsonb)
    from public.theater_tickets t
    join public.theater_bookings b on b.id = t.booking_id
    join public.theater_zones z on z.id = t.zone_id
    left join public.user_wallets w on w.wallet_code = b.wallet_code
    left join public.users u on u.username = w.username
   where b.event_id = p_event_id and t.lucky_won_at is not null
$$;

create or replace function public.admin_draw_theater_lucky(p_admin_username text, p_event_id bigint) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare
  e public.theater_events;
  v_n int;
  v_prize_name text;
begin
  if not public.is_admin_or_ceo(p_admin_username) then
    return jsonb_build_object('status','error','message','ไม่มีสิทธิ์ทำรายการนี้');
  end if;
  perform public.theater_draw_due(p_event_id);
  select * into e from public.theater_events where id = p_event_id for update;
  if not found or e.status = 'cancelled' then
    return jsonb_build_object('status','error','message','ไม่พบการแสดง หรือถูกยกเลิกไปแล้ว');
  end if;
  if e.lucky_drawn_at is not null then
    return jsonb_build_object('status','error','message','สุ่มผู้โชคดีไปแล้ว');
  end if;
  if jsonb_array_length(e.lucky_prize) = 0 then
    return jsonb_build_object('status','error','message','ยังไม่ได้ตั้งรางวัลลุ้นโชค (กดบันทึกก่อน)');
  end if;
  if exists (select 1 from public.theater_rounds where event_id = e.id and close_at > now()) then
    return jsonb_build_object('status','error','message','ต้องปิดการขายทุกรอบก่อนจึงจะสุ่มได้');
  end if;

  with picked as (
    select t.id from public.theater_tickets t join public.theater_bookings b on b.id = t.booking_id
     where b.event_id = e.id and b.status = 'paid' and t.seat_no is not null
     order by random() limit e.lucky_winner_count
  )
  update public.theater_tickets t set lucky_won_at = now() from picked where t.id = picked.id;
  get diagnostics v_n = row_count;
  if v_n = 0 then
    return jsonb_build_object('status','error','message','ยังไม่มีผู้ถือบัตรที่ได้ที่นั่ง');
  end if;

  update public.theater_events set lucky_drawn_at = now(), lucky_drawn_by = p_admin_username, updated_at = now() where id = e.id;

  select coalesce(r->>'label', 'รางวัลพิเศษ') into v_prize_name
    from jsonb_array_elements(e.lucky_prize) r where r->>'kind' = 'item' limit 1;
  insert into public.notifications (writer, action, avatar, role, recipient_username, notif_type)
  select 'BLM48', 'ยินดีด้วย! คุณคือผู้โชคดีได้รับ ' || coalesce(v_prize_name, 'รางวัลพิเศษ') || ' จาก ' || e.title
                  || ' กดรับได้ที่ My Bookings', e.cover_url, 'Admin', w.username, 'theater'
    from (select distinct b.wallet_code from public.theater_tickets t join public.theater_bookings b on b.id = t.booking_id
           where b.event_id = e.id and t.lucky_won_at is not null) x
    join public.user_wallets w on w.wallet_code = x.wallet_code;

  return jsonb_build_object('status','success','winners', public.theater_lucky_winners(e.id));
end;
$$;

create or replace function public.claim_theater_lucky(p_username text, p_booking_id bigint) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare
  b public.theater_bookings;
  e public.theater_events;
  v_wc text := public.wallet_code_of(p_username);
  v_won int;
  v_row jsonb;
  v_amount numeric;
begin
  select * into b from public.theater_bookings where id = p_booking_id and wallet_code = v_wc for update;
  if not found then return jsonb_build_object('status','fail','message','ไม่พบการจองนี้ค่ะ'); end if;
  if b.status <> 'paid' then return jsonb_build_object('status','fail','message','การจองนี้ถูกยกเลิกแล้วค่ะ'); end if;
  if b.lucky_claimed_at is not null then return jsonb_build_object('status','fail','message','รับรางวัลไปแล้วค่ะ'); end if;
  select count(*) into v_won from public.theater_tickets where booking_id = b.id and lucky_won_at is not null;
  if v_won = 0 then return jsonb_build_object('status','fail','message','บัตรนี้ไม่ได้รับรางวัลค่ะ'); end if;
  select * into e from public.theater_events where id = b.event_id;
  perform 1 from public.users where username = p_username for update;

  for v_row in select * from jsonb_array_elements(public.theater_expand_rewards(e.lucky_prize, v_won)) loop
    v_amount := coalesce((v_row->>'amount')::numeric, 0);
    if v_row->>'kind' = 'item' then
      insert into public.inventory (wallet_code, item_type, collection_id, item_name, image_url)
        values (v_wc, coalesce(nullif(v_row->>'itemType',''),'SSR'), coalesce(v_row->>'collectionId','theater_' || e.id),
                v_row->>'label', v_row->>'imageUrl');
    elsif v_row->>'kind' = 'cookie' and v_amount > 0 then
      update public.users set cookie = cookie + v_amount, updated_at = now() where username = p_username;
      insert into public.wallet_logs (wallet_code, action, target, amount) values (v_wc, 'Theater Lucky Draw', e.title || ' (Cookie)', v_amount);
    elsif v_row->>'kind' = 'ge_token' and v_amount > 0 then
      update public.users set ge_token = ge_token + v_amount, updated_at = now() where username = p_username;
      insert into public.wallet_logs (wallet_code, action, target, amount) values (v_wc, 'Theater Lucky Draw', e.title || ' (GE Token)', v_amount);
    end if;
  end loop;

  update public.theater_bookings set lucky_claimed_at = now() where id = b.id;
  return jsonb_build_object('status','success',
    'wallet', (select jsonb_build_object('token', token, 'cookie', cookie, 'geToken', ge_token) from public.users where username = p_username));
end;
$$;

-- add the lucky fields to the 4 existing RPCs by patching their live definitions
do $patch$
declare
  v_def text;
  v_new text;
  v_fn record;
begin
  for v_fn in select * from (values
    ('public.admin_save_theater_event(text,jsonb)',
     $a$souvenirs = coalesce(p_event->'souvenirs','[]'::jsonb),$a$,
     $a$souvenirs = coalesce(p_event->'souvenirs','[]'::jsonb),
    lucky_prize = case when lucky_drawn_at is null then coalesce(p_event->'luckyPrize','[]'::jsonb) else lucky_prize end,
    lucky_winner_count = case when lucky_drawn_at is null then least(greatest(coalesce(nullif(p_event->>'luckyWinnerCount','')::int, 1), 1), 100) else lucky_winner_count end,$a$),
    ('public.admin_get_theater_event(text,bigint)',
     $a$'souvenirs', e.souvenirs, 'endedAt', public.theater_ended_at(e),$a$,
     $a$'souvenirs', e.souvenirs, 'endedAt', public.theater_ended_at(e),
    'luckyPrize', e.lucky_prize, 'luckyWinnerCount', e.lucky_winner_count, 'luckyDrawnAt', e.lucky_drawn_at,
    'luckyCanDraw', not exists (select 1 from public.theater_rounds x where x.event_id = e.id and x.close_at > now()),
    'luckyWinners', public.theater_lucky_winners(e.id),$a$),
    ('public.get_theater_event(text,bigint)',
     $a$'isPast', v_e.event_date < public.theater_today(),$a$,
     $a$'isPast', v_e.event_date < public.theater_today(),
    'souvenirs', v_e.souvenirs, 'luckyPrize', v_e.lucky_prize, 'luckyWinnerCount', v_e.lucky_winner_count,
    'luckyDrawnAt', v_e.lucky_drawn_at,$a$),
    ('public.theater_booking_json(bigint,boolean)',
     $a$'souvenirsClaimedAt', b.souvenirs_claimed_at,$a$,
     $a$'souvenirsClaimedAt', b.souvenirs_claimed_at,
      'lucky', case when jsonb_array_length(e.lucky_prize) > 0 then jsonb_build_object(
          'prize', e.lucky_prize, 'winnerCount', e.lucky_winner_count, 'drawnAt', e.lucky_drawn_at,
          'claimedAt', b.lucky_claimed_at,
          'wonSeats', coalesce((select jsonb_agg(public.theater_seat_label(z.seat_prefix, t.seat_no) order by t.idx)
                                  from public.theater_tickets t where t.booking_id = b.id and t.lucky_won_at is not null), '[]'::jsonb)) end,$a$)
  ) as f(sig, old_txt, new_txt) loop
    v_def := pg_get_functiondef(v_fn.sig::regprocedure);
    v_new := replace(v_def, v_fn.old_txt, v_fn.new_txt);
    if v_new = v_def then raise exception 'patch anchor not found in %', v_fn.sig; end if;
    execute v_new;
  end loop;
end
$patch$;

revoke execute on function public.theater_lucky_winners(bigint) from public, anon, authenticated;

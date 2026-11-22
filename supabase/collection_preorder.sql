-- 2026-11-22 Collection pre-order
-- An admin can turn a Shop Collection (gacha_*) into a pre-order:
--   * the draw still happens at checkout (stock is reserved), but the cart line is held as 'waiting'
--     until the admin ships the whole collection (admin_ship_collection_preorder), then it becomes
--     'ready' and the buyer Redeems it like every other pre-order line
--   * optional bonus Token / GE Token / Cookie per draw (x5 = 5 times the bonus)
--   * bonus timing: 'purchase' = credited to the wallet right at checkout (wallet_logs + notification)
--                   'ship'     = travels with the goods and is credited when the buyer Redeems
-- Existing functions are patched in place (anchor replace) so their other behaviour stays identical.

alter table public.collections
  add column if not exists is_preorder boolean not null default false,
  add column if not exists preorder_bonus_token numeric not null default 0,
  add column if not exists preorder_bonus_ge_token numeric not null default 0,
  add column if not exists preorder_bonus_cookie numeric not null default 0,
  add column if not exists preorder_bonus_timing text not null default 'ship',
  add column if not exists preorder_delivery_info text,
  add column if not exists preorder_shipped_at timestamptz;

do $$ begin
  alter table public.collections add constraint collections_preorder_bonus_timing_chk
    check (preorder_bonus_timing in ('purchase', 'ship'));
exception when duplicate_object then null; end $$;

alter table public.shop_order_items
  add column if not exists is_preorder boolean not null default false,
  add column if not exists preorder_bonus jsonb;

create index if not exists shop_order_items_waiting_ref_idx
  on public.shop_order_items (ref_id) where status = 'waiting';

-- patch helper: replace one anchor inside a function body, fail loudly if the anchor is missing
create or replace function pg_temp.patch_fn(p_sig regprocedure, p_from text, p_to text)
returns void language plpgsql as $$
declare v_def text;
begin
  v_def := pg_get_functiondef(p_sig);
  if position(p_from in v_def) = 0 then
    raise exception 'anchor not found in %: %', p_sig, left(p_from, 80);
  end if;
  execute replace(v_def, p_from, p_to);
end $$;

-- ===== bonus credit helper (internal) =====
create or replace function public._grant_preorder_bonus(p_username text, p_name text,
  p_token numeric, p_ge numeric, p_cookie numeric)
returns void language plpgsql security definer set search_path to 'public' as $$
declare v_wc text := public.wallet_code_of(p_username);
begin
  if coalesce(p_token, 0) > 0 then
    update public.users set token = token + p_token, updated_at = now() where username = p_username;
    insert into public.wallet_logs (wallet_code, action, target, amount) values (v_wc, 'Pre-order Bonus', p_name || ' - Token', p_token);
  end if;
  if coalesce(p_ge, 0) > 0 then
    update public.users set ge_token = ge_token + p_ge, updated_at = now() where username = p_username;
    insert into public.wallet_logs (wallet_code, action, target, amount) values (v_wc, 'Pre-order Bonus', p_name || ' - GE Token', p_ge);
  end if;
  if coalesce(p_cookie, 0) > 0 then
    update public.users set cookie = cookie + p_cookie, updated_at = now() where username = p_username;
    insert into public.wallet_logs (wallet_code, action, target, amount) values (v_wc, 'Pre-order Bonus', p_name || ' - Cookie', p_cookie);
  end if;
end $$;
revoke all on function public._grant_preorder_bonus(text, text, numeric, numeric, numeric) from public, anon, authenticated;

-- "+100 Token, +50 Cookie" (no emoji)
create or replace function public._preorder_bonus_text(p_token numeric, p_ge numeric, p_cookie numeric)
returns text language sql immutable as $$
  select nullif(concat_ws(', ',
    case when coalesce(p_token, 0) > 0 then '+' || to_char(p_token, 'FM999,999,999') || ' Token' end,
    case when coalesce(p_ge, 0) > 0 then '+' || to_char(p_ge, 'FM999,999,999') || ' GE Token' end,
    case when coalesce(p_cookie, 0) > 0 then '+' || to_char(p_cookie, 'FM999,999,999') || ' Cookie' end), '');
$$;

-- ===== buy_gacha_item: a pre-order collection can only be bought through the cart =====
select pg_temp.patch_fn('public.buy_gacha_item(text, text, integer)'::regprocedure,
$a$  if p_pull_count = 5 and not coalesce(v_col.allow_x5, true) then$a$,
$a$  if coalesce(v_col.is_preorder, false) and coalesce(current_setting('blm48.in_checkout', true), '') <> '1' then
    return jsonb_build_object('status','fail','message','This collection is a pre-order. Please order it through the cart.');
  end if;

  if p_pull_count = 5 and not coalesce(v_col.allow_x5, true) then$a$);

-- ===== shop_checkout: hold pre-order collection lines + bonus =====
select pg_temp.patch_fn('public.shop_checkout(text, jsonb)'::regprocedure,
$a$  v_total numeric := 0;$a$,
$a$  v_total numeric := 0;
  v_is_pre boolean;
  v_bonus jsonb;
  v_bt numeric; v_bg numeric; v_bc numeric;
  v_bonus_lines jsonb := '[]'::jsonb;
  v_sender record;$a$);

select pg_temp.patch_fn('public.shop_checkout(text, jsonb)'::regprocedure,
$a$  begin
    -- เลขคำสั่งซื้อแบบ iAM$a$,
$a$  -- buy_gacha_item ยอมขายคอลเลกชันพรีออเดอร์เฉพาะเมื่อเรียกจากตะกร้านี้
  perform set_config('blm48.in_checkout', '1', true);

  begin
    -- เลขคำสั่งซื้อแบบ iAM$a$);

select pg_temp.patch_fn('public.shop_checkout(text, jsonb)'::regprocedure,
$a$      v_status := 'ready';
      v_preorder_id := null;$a$,
$a$      v_status := 'ready';
      v_preorder_id := null;
      v_is_pre := false;
      v_bonus := null;$a$);

select pg_temp.patch_fn('public.shop_checkout(text, jsonb)'::regprocedure,
$a$        delete from public.inventory
          where wallet_code = public.wallet_code_of(p_username) and id > v_inv_before
            and (collection_id = v_ref or coalesce(v_col.draw_mode, 'normal') = 'lucky');
      end if;$a$,
$a$        delete from public.inventory
          where wallet_code = public.wallet_code_of(p_username) and id > v_inv_before
            and (collection_id = v_ref or coalesce(v_col.draw_mode, 'normal') = 'lucky');

        -- คอลเลกชันพรีออเดอร์: สุ่ม+จองสต๊อกแล้ว แต่ของรอจัดส่งพร้อมกัน (Redeem ได้หลังแอดมินกดจัดส่ง)
        if coalesce(v_col.is_preorder, false) and coalesce(v_col.draw_mode, 'normal') <> 'lucky' then
          v_is_pre := true;
          v_status := 'waiting';
          v_bt := coalesce(v_col.preorder_bonus_token, 0) * v_variant * v_qty;
          v_bg := coalesce(v_col.preorder_bonus_ge_token, 0) * v_variant * v_qty;
          v_bc := coalesce(v_col.preorder_bonus_cookie, 0) * v_variant * v_qty;
          if v_bt + v_bg + v_bc > 0 then
            v_bonus := jsonb_build_object('token', v_bt, 'geToken', v_bg, 'cookie', v_bc,
              'timing', v_col.preorder_bonus_timing, 'credited', v_col.preorder_bonus_timing = 'purchase');
            if v_col.preorder_bonus_timing = 'purchase' then
              perform public._grant_preorder_bonus(p_username, coalesce(v_col.collection_name, v_ref), v_bt, v_bg, v_bc);
              v_bonus_lines := v_bonus_lines || jsonb_build_object('name', coalesce(v_col.collection_name, v_ref),
                'text', public._preorder_bonus_text(v_bt, v_bg, v_bc), 'image', v_col.cover_image);
            else
              -- ไปพร้อมของ: เข้ากระเป๋าตอนกด Redeem
              if v_bt > 0 then v_rewards := v_rewards || jsonb_build_object('kind','token','label','Token','amount',v_bt,'bonus',true); end if;
              if v_bg > 0 then v_rewards := v_rewards || jsonb_build_object('kind','ge_token','label','GE Token','amount',v_bg,'bonus',true); end if;
              if v_bc > 0 then v_rewards := v_rewards || jsonb_build_object('kind','cookie','label','Cookie','amount',v_bc,'bonus',true); end if;
            end if;
          end if;
        end if;
      end if;$a$);

select pg_temp.patch_fn('public.shop_checkout(text, jsonb)'::regprocedure,
$a$         preorder_order_id, rewards, status)$a$,
$a$         preorder_order_id, rewards, status, is_preorder, preorder_bonus)$a$);

select pg_temp.patch_fn('public.shop_checkout(text, jsonb)'::regprocedure,
$a$         v_preorder_id, v_rewards, v_status);$a$,
$a$         v_preorder_id, v_rewards, v_status, v_is_pre or v_kind = 'preorder', v_bonus);$a$);

select pg_temp.patch_fn('public.shop_checkout(text, jsonb)'::regprocedure,
$a$    update public.shop_orders set total_tokens = v_total where id = v_order_id;$a$,
$a$    update public.shop_orders set total_tokens = v_total where id = v_order_id;

    -- แจ้งเตือนโบนัสพรีออเดอร์ที่เข้ากระเป๋าทันที (ผู้ส่ง = บัญชี BLM48)
    if jsonb_array_length(v_bonus_lines) > 0 then
      select name, profile_img into v_sender from public.users where username = '48-480';
      for v_it in select * from jsonb_array_elements(v_bonus_lines) loop
        insert into public.notifications (recipient_username, writer, action, avatar, role, notif_type)
          values (p_username, coalesce(v_sender.name, 'BLM48'),
                  'ได้รับโบนัสพรีออเดอร์ "' || (v_it->>'name') || '" ' || (v_it->>'text') || ' เข้ากระเป๋าแล้วค่ะ',
                  v_sender.profile_img, 'Admin', 'wallet');
      end loop;
    end if;$a$);

-- ===== redeem_shop_order: Token rewards + bonus ledger rows =====
select pg_temp.patch_fn('public.redeem_shop_order(text, bigint)'::regprocedure,
$a$        update public.users set cookie = cookie + v_amount, updated_at = now() where username = p_username;$a$,
$a$        update public.users set cookie = cookie + v_amount, updated_at = now() where username = p_username;
        if coalesce((v_row->>'bonus')::boolean, false) and v_amount > 0 then
          insert into public.wallet_logs (wallet_code, action, target, amount)
            values (public.wallet_code_of(p_username), 'Pre-order Bonus', regexp_replace(v_line.name, ' \(Draw ×\d+\)$', '') || ' - Cookie', v_amount);
        end if;
      elsif v_row->>'kind' = 'token' then
        v_amount := coalesce((v_row->>'amount')::numeric, 0);
        if v_amount > 0 then
          update public.users set token = token + v_amount, updated_at = now() where username = p_username;
          insert into public.wallet_logs (wallet_code, action, target, amount)
            values (public.wallet_code_of(p_username), 'Pre-order Bonus', regexp_replace(v_line.name, ' \(Draw ×\d+\)$', '') || ' - Token', v_amount);
        end if;$a$);

select pg_temp.patch_fn('public.redeem_shop_order(text, bigint)'::regprocedure,
$a$            values (public.wallet_code_of(p_username), 'Preorder Shipped', v_line.name, v_amount);$a$,
$a$            values (public.wallet_code_of(p_username),
                    case when coalesce((v_row->>'bonus')::boolean, false) then 'Pre-order Bonus' else 'Preorder Shipped' end,
                    case when coalesce((v_row->>'bonus')::boolean, false) then regexp_replace(v_line.name, ' \(Draw ×\d+\)$', '') || ' - GE Token' else v_line.name end,
                    v_amount);$a$);

-- ===== cookie history: bonus cookies come from wallet_logs, not the "Cookies Purchased" branch =====
select pg_temp.patch_fn('public.get_my_cookie_history(text, integer, integer)'::regprocedure,
$a$     where o.wallet_code = me.wc and i.status = 'redeemed' and r->>'kind' = 'cookie'$a$,
$a$     where o.wallet_code = me.wc and i.status = 'redeemed' and r->>'kind' = 'cookie'
       and not coalesce((r->>'bonus')::boolean, false)
    union all
    select w.created_at, 'Pre-order Bonus', regexp_replace(w.target, ' - Cookie$', ''), w.amount
      from wallet_logs w, me
     where w.wallet_code = me.wc and w.action = 'Pre-order Bonus' and w.target like '% - Cookie'$a$);

-- ===== get_shop_order: expose pre-order flag + bonus per line =====
select pg_temp.patch_fn('public.get_shop_order(text, bigint)'::regprocedure,
$a$          'redeemedAt', l.redeemed_at,$a$,
$a$          'redeemedAt', l.redeemed_at,
          'isPreorder', l.is_preorder or l.kind = 'preorder',
          'bonus', l.preorder_bonus,
          'deliveryInfo', case when l.kind = 'gacha' then (select c.preorder_delivery_info from public.collections c where c.collection_id = l.ref_id) end,$a$);

-- ===== get_gacha_collections: pre-order info for Shop / product page =====
select pg_temp.patch_fn('public.get_gacha_collections(text)'::regprocedure,
$a$    'IsLucky', c.draw_mode = 'lucky',$a$,
$a$    'IsLucky', c.draw_mode = 'lucky',
    'IsPreorder', coalesce(c.is_preorder, false) and coalesce(c.draw_mode, 'normal') <> 'lucky',
    'PreorderBonus', jsonb_build_object('token', c.preorder_bonus_token, 'geToken', c.preorder_bonus_ge_token, 'cookie', c.preorder_bonus_cookie),
    'PreorderBonusTiming', c.preorder_bonus_timing,
    'PreorderDeliveryInfo', c.preorder_delivery_info,$a$);

-- ===== admin_get_collection: pre-order settings + waiting/shipped counts =====
select pg_temp.patch_fn('public.admin_get_collection(text, text)'::regprocedure,
$a$'isLucky', c.draw_mode = 'lucky',$a$,
$a$'isLucky', c.draw_mode = 'lucky',
    'preorder', jsonb_build_object('on', c.is_preorder, 'bonusToken', c.preorder_bonus_token, 'bonusGeToken', c.preorder_bonus_ge_token,
      'bonusCookie', c.preorder_bonus_cookie, 'timing', c.preorder_bonus_timing, 'deliveryInfo', c.preorder_delivery_info,
      'shippedAt', c.preorder_shipped_at,
      'waitingLines', (select count(*) from public.shop_order_items l where l.kind = 'gacha' and l.ref_id = c.collection_id and l.status = 'waiting'),
      'waitingOrders', (select count(distinct l.order_id) from public.shop_order_items l where l.kind = 'gacha' and l.ref_id = c.collection_id and l.status = 'waiting'),
      'waitingBuyers', (select count(distinct o.wallet_code) from public.shop_order_items l join public.shop_orders o on o.id = l.order_id
                          where l.kind = 'gacha' and l.ref_id = c.collection_id and l.status = 'waiting'),
      'waitingDraws', (select coalesce(sum(l.variant * l.quantity), 0) from public.shop_order_items l where l.kind = 'gacha' and l.ref_id = c.collection_id and l.status = 'waiting'),
      'shippedLines', (select count(*) from public.shop_order_items l where l.kind = 'gacha' and l.ref_id = c.collection_id and l.is_preorder and l.status <> 'waiting')),$a$);

-- ===== admin_save_collection: save pre-order settings (only when p_col has "preorder") =====
select pg_temp.patch_fn('public.admin_save_collection(text, text, jsonb, jsonb)'::regprocedure,
$a$  v_keep bigint[] := '{}'; v_stock bigint; v_count int;$a$,
$a$  v_keep bigint[] := '{}'; v_stock bigint; v_count int;
  v_pre jsonb; v_pre_on boolean; v_bt numeric; v_bg numeric; v_bc numeric; v_timing text;$a$);

select pg_temp.patch_fn('public.admin_save_collection(text, text, jsonb, jsonb)'::regprocedure,
$a$  return jsonb_build_object('status','success','collectionId', v_id,$a$,
$a$  if jsonb_typeof(p_col->'preorder') = 'object' then
    v_pre := p_col->'preorder';
    v_pre_on := coalesce((v_pre->>'on')::boolean, false);
    v_bt := coalesce(nullif(v_pre->>'bonusToken', '')::numeric, 0);
    v_bg := coalesce(nullif(v_pre->>'bonusGeToken', '')::numeric, 0);
    v_bc := coalesce(nullif(v_pre->>'bonusCookie', '')::numeric, 0);
    v_timing := coalesce(v_pre->>'timing', 'ship');
    if v_pre_on and coalesce(v_old.draw_mode, 'normal') = 'lucky' then
      raise exception using message = 'Lucky Box cannot be sold as a pre-order';
    end if;
    if v_bt < 0 or v_bg < 0 or v_bc < 0 or v_bt <> trunc(v_bt) or v_bg <> trunc(v_bg) or v_bc <> trunc(v_bc)
       or greatest(v_bt, v_bg, v_bc) > 1000000 then
      raise exception using message = 'Bonus amounts must be whole numbers from 0 to 1,000,000';
    end if;
    if v_timing not in ('purchase', 'ship') then
      raise exception using message = 'Choose when the bonus is given';
    end if;
    if not v_pre_on and coalesce(v_old.is_preorder, false)
       and exists (select 1 from public.shop_order_items where kind = 'gacha' and ref_id = v_id and status = 'waiting') then
      raise exception using message = 'Some pre-orders are still waiting to ship. Ship them before turning pre-order off';
    end if;
    update public.collections set is_preorder = v_pre_on,
      preorder_bonus_token = v_bt, preorder_bonus_ge_token = v_bg, preorder_bonus_cookie = v_bc,
      preorder_bonus_timing = v_timing,
      preorder_delivery_info = nullif(btrim(coalesce(v_pre->>'deliveryInfo', '')), '')
    where collection_id = v_id;
  end if;

  return jsonb_build_object('status','success','collectionId', v_id,$a$);

-- ===== new: ship every waiting pre-order line of a collection =====
create or replace function public.admin_ship_collection_preorder(p_admin_username text, p_collection_id text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_col public.collections;
  v_lines int;
  v_order_ids bigint[];
  v_orders int;
  v_buyers int;
  v_sender record;
begin
  if not public.is_admin_or_ceo(p_admin_username) then
    return jsonb_build_object('status','error','message','You do not have permission to do this');
  end if;
  select * into v_col from public.collections where collection_id = p_collection_id and collection_id like 'gacha\_%' for update;
  if not found then return jsonb_build_object('status','error','message','Collection not found'); end if;

  with up as (
    update public.shop_order_items set status = 'ready'
     where kind = 'gacha' and ref_id = p_collection_id and status = 'waiting'
     returning order_id
  ) select count(*), array_agg(distinct order_id) into v_lines, v_order_ids from up;

  if v_lines = 0 then
    return jsonb_build_object('status','error','message','No pre-orders are waiting to ship');
  end if;
  v_orders := coalesce(array_length(v_order_ids, 1), 0);

  -- one notification per buyer (writer = BLM48 account)
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
end $$;
grant execute on function public.admin_ship_collection_preorder(text, text) to anon, authenticated;

-- 🔁 Trading Market: pre-order items can't be traded until they ship (2026-11-24, migration trading_market_preorder_lock)
-- User: "สินค้าพรีออเดอร์ถ้ายังไม่ถึงเวลาจัดส่งไม่สามารถแลกได้นะ"
-- A pre-order Collection (collections.is_preorder) counts as released for trading only after the admin ships it
-- (admin_ship_collection_preorder sets preorder_shipped_at). Before that it can't be offered, wanted or listed.
-- Found when added: the Christmas pre-orders gacha_261116_e0262 / gacha_261122_c3cc1 (BLM48 PhotoCard) were already
-- in the Want picker because sale_start_at had passed (nobody owned them, no open listing used them).
-- _coaster_collection_released is used only by the trade RPCs (_coaster_rarity, board, catalog, my tradable items).
-- Old-style pre-order products (inventory.item_type 'Preorder') were already excluded in trading_market.

create or replace function public._coaster_collection_released(p_collection_id text)
returns boolean
language sql stable security definer set search_path to 'public'
as $$
  select exists (
    select 1 from public.collections c
     where c.collection_id = p_collection_id
       and not (coalesce(c.is_preorder, false) and c.preorder_shipped_at is null)
       and ( (c.sale_start_at is not null and c.sale_start_at <= now())
          or (c.sale_start_at is null and exists (select 1 from public.inventory i where i.collection_id = c.collection_id)) )
  )
$$;
revoke execute on function public._coaster_collection_released(text) from public, anon, authenticated;

-- 2026-11-15 สมุดสะสม Collection Book (collection_book.html / collection_set.html)
-- ทุกชุดของสะสมจากตาราง items (การ์ด/Coaster/Badge/PhotoCard) แยกเป็น "ชุด" ตาม reward_collection_name
-- (photo_card + SSR_card ของคอนเสิร์ตรวมเป็นชุดเดียวกัน) พร้อมเลขช่องและจำนวนที่ผู้ใช้มี
-- ไม่รวม Lucky Box, BLM48 Cafe, Photobook และชุดที่ยังไม่ถึงเวลาเปิดขาย
-- 2026-11-26 Collection แบบ Pre-order (เช่น Christmas Project 2) ไม่แสดงจนกว่า Admin จะกดจัดส่ง (preorder_shipped_at)
-- ช่องที่ยังไม่มี: ส่งรูป (หน้าเว็บใส่ฟิลเตอร์เทาดำ) แต่ไม่ส่งชื่อ/ความหายาก
-- ชุดที่ตรงกับหมวด Pre-order (Concert 2026 Marry Me) ใช้ปกของ Pre-order ที่แพงที่สุด
CREATE OR REPLACE FUNCTION public.get_collection_album(p_username text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with wc as (select public.wallet_code_of(p_username) as code),
  owned as (
    select v.collection_id, v.item_name, count(*) as qty, min(v.created_at) as first_at
    from public.inventory v, wc
    where v.wallet_code = wc.code
    group by 1, 2
  ),
  cards as (
    select
      public.reward_collection_name(i.collection_id, i.name) as set_name,
      c.collection_id, c.category, c.group_name, c.cover_image, c.back_image, c.status, c.sale_start_at,
      i.id, i.name, i.image_url, i.tag,
      (coalesce(i.tag, '') ilike 'ssr' or i.collection_id = 'SSR_card') as is_ssr,
      coalesce(o.qty, 0) as qty,
      o.first_at,
      (select ba.image_url from public.inventory_back_art ba
        where ba.collection_id = i.collection_id and ba.item_name = i.name) as back_img
    from public.items i
    join public.collections c on c.collection_id = i.collection_id
    left join owned o on o.collection_id = i.collection_id and o.item_name = i.name
    where coalesce(c.draw_mode, 'normal') <> 'lucky'
      and c.category not in ('BLM48 Cafe', 'BLM48 Photobook')
      and (c.sale_start_at is null or c.sale_start_at <= now())
      -- pre-order collections stay hidden until the admin ships them
      and (not coalesce(c.is_preorder, false) or c.preorder_shipped_at is not null)
      -- show only collections that have actually gone on sale (opened day 1 onward)
      and (coalesce(c.status, '') ilike any (array['open', 'active', 'sold out'])
           or c.open_notified_at is not null
           or exists (select 1 from public.inventory sv where sv.collection_id = c.collection_id))
  ),
  numbered as (
    select *,
      row_number() over (partition by set_name
        order by is_ssr, (coalesce(tag, '') = 'afterparty'), id) as no
    from cards
    where set_name is not null
  ),
  sets as (
    select
      set_name,
      min(collection_id) filter (where collection_id <> 'SSR_card') as set_key,
      min(category) filter (where collection_id <> 'SSR_card') as category,
      case when bool_or(group_name = 'Both') then 'Both' when bool_or(group_name = 'NPT48') then 'NPT48' else 'BLM48' end as grp,
      max(cover_image) as cover,
      max(back_image) as back_image,
      (array_agg(image_url order by no) filter (where not is_ssr))[1] as cover_fallback,
      max(sale_start_at) as released_at,
      bool_or(coalesce(status, '') ilike 'open') as is_open,
      count(*) as total,
      count(*) filter (where qty > 0) as owned_count,
      max(first_at) as last_new_at,
      jsonb_agg(jsonb_build_object(
        'no', no,
        'name', case when qty > 0 then name end,
        'owned', qty > 0,
        'qty', qty,
        -- ของที่ยังไม่มี: ส่งรูปไปโชว์แบบเทาดำ แต่ไม่ส่งชื่อ/ความหายาก
        'img', image_url,
        'ssr', case when qty > 0 then is_ssr end,
        'backImg', case when qty > 0 then back_img end,
        'collectionId', collection_id
      ) order by no) as cards
    from numbered
    group by set_name
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'key', set_key,
    'name', set_name,
    'category', category,
    'group', grp,
    -- ชุดที่เป็นสินค้า Pre-order: ใช้ปกของ Pre-order ที่แพงที่สุด
    'cover', coalesce(
      (select pp.cover_image from public.preorder_products pp
        where pp.category = set_name and coalesce(pp.cover_image, '') <> ''
        order by pp.cost_tokens desc limit 1),
      cover, cover_fallback),
    'backImage', back_image,
    'isOpen', is_open,
    'total', total,
    'owned', owned_count,
    'cards', cards
  ) order by is_open desc, released_at desc nulls last, set_name), '[]'::jsonb)
  from sets;
$function$;

grant execute on function public.get_collection_album(text) to anon, authenticated;

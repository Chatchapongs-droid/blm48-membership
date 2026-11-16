-- 2026-11-16: Coaster Trade only allows Coasters from collections that have actually gone on sale.
-- Bug: listing #118 wanted "Untitled design - 1" from gacha_261116_e0262 (Merry Christmas), a draft
-- collection (status Closed, no sale date, nobody owns it) that the catalog still listed.
-- "Released" = sale start date has passed, or (old collections with no dates) somebody already owns an item.
create or replace function public._coaster_collection_released(p_collection_id text)
returns boolean
language sql stable security definer set search_path to 'public'
as $$
  select exists (
    select 1 from public.collections c
     where c.collection_id = p_collection_id
       and ( (c.sale_start_at is not null and c.sale_start_at <= now())
          or (c.sale_start_at is null and exists (select 1 from public.inventory i where i.collection_id = c.collection_id)) )
  )
$$;

CREATE OR REPLACE FUNCTION public._coaster_rarity(p_collection_id text, p_name text)
 RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  select case when coalesce(it.tag,'') = 'SSR' then 'SSR' else 'Normal' end
    from public.items it join public.collections c on c.collection_id = it.collection_id
   where it.collection_id = p_collection_id and it.name = p_name
     and c.category = 'Coaster' and c.collection_id not ilike 'gacha_npt%' and c.group_name <> 'NPT48'
     and public._coaster_collection_released(c.collection_id)
   limit 1
$function$;

CREATE OR REPLACE FUNCTION public.get_coaster_trade_catalog()
 RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  select coalesce(jsonb_agg(jsonb_build_object('collectionId', it.collection_id, 'collectionName', c.collection_name,
           'name', it.name, 'imageUrl', it.image_url, 'rarity', case when coalesce(it.tag,'') = 'SSR' then 'SSR' else 'Normal' end)
           order by c.collection_name, it.id), '[]'::jsonb)
    from public.items it join public.collections c on c.collection_id = it.collection_id
   where c.category = 'Coaster' and c.collection_id not ilike 'gacha_npt%' and c.group_name <> 'NPT48'
     and public._coaster_collection_released(c.collection_id)
$function$;

CREATE OR REPLACE FUNCTION public.get_my_tradable_coasters(p_username text)
 RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  select coalesce(jsonb_agg(x order by x->>'rarity' desc, x->>'collectionName', x->>'name'), '[]'::jsonb) from (
    select jsonb_build_object('collectionId', i.collection_id, 'collectionName', c.collection_name, 'name', i.item_name,
             'imageUrl', min(i.image_url), 'rarity', case when coalesce(it.tag,'') = 'SSR' then 'SSR' else 'Normal' end,
             'count', count(*), 'inventoryId', min(i.id)) x
      from public.inventory i
      join public.collections c on c.collection_id = i.collection_id and c.category = 'Coaster' and c.collection_id not ilike 'gacha_npt%' and c.group_name <> 'NPT48'
      join public.items it on it.collection_id = i.collection_id and it.name = i.item_name
     where i.wallet_code = public.wallet_code_of(p_username) and i.item_type = 'Coaster'
       and public._coaster_collection_released(c.collection_id)
     group by i.collection_id, c.collection_name, i.item_name, it.tag
  ) s
$function$;

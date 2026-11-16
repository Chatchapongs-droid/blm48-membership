-- 2026-11-16: collections.group_name (BLM48 / NPT48 / Both) chosen in admin_collection.html.
-- Applied to Supabase as migrations: collections_group_name, admin_collection_messages_english,
-- coaster_trade_exclude_npt_group. Summary of what they do:

alter table public.collections add column if not exists group_name text not null default 'BLM48';
alter table public.collections add constraint collections_group_name_check check (group_name in ('BLM48','NPT48','Both'));
update public.collections set group_name = 'NPT48'
 where category ~* '^NPT48' or collection_id like 'gacha\_npt%';

-- Function changes (patched in place with replace() on pg_get_functiondef):
-- * admin_get_collection / admin_list_collections: return 'group', c.group_name
-- * admin_save_collection: group_name = p_col->>'group' when it is BLM48/NPT48/Both (else unchanged)
-- * get_inventory: each row also returns 'group' (max(c.group_name)); null for rows without a collection
-- * get_collection_album: set 'group' = 'Both' if any collection in the set is Both, else NPT48 if any, else BLM48
-- * admin_save_collection / admin_get_collection / admin_delete_collection / admin_list_collections:
--   all user-facing messages translated to English
-- * _coaster_rarity / get_coaster_trade_catalog / get_my_tradable_coasters: also exclude group_name = 'NPT48'

-- Category stored in collections.category (admin page composes it from Group + Category):
--   NPT48 -> 'NPT48 <Type>'   BLM48 -> 'Coaster' or 'BLM48 <Type>'   Both -> '<Type>' (no group prefix)

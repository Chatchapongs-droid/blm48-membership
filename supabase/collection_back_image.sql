-- 🃏 Collection card-back art for the 3D viewer
-- 2026-11-04 (migration collection_back_images, applied from another session; its page code never reached the repo):
--   collections.back_image + back_style ('shape' default | 'card'), get_collection_back_images() (public map, granted to anon),
--   admin_set_collection_back_image(admin, collection_id, url, style).
-- 2026-11-05 (migrations collection_back_image + collection_back_image_reuse):
--   admin_get_collection returns backImage/backStyle; admin_save_collection writes them only when p_col carries the keys
--   (an older cached editor that doesn't send them leaves the back untouched).
--   item-3d-viewer.js loads get_collection_back_images() and prefers it over its built-in COLLECTION_BG map.
--   back_style: 'card' = full image with rounded corners (photocards), 'shape' = transparent PNG drawn as-is (coasters).
--   Data fix: gacha_261104_fcbce (Magic Hour) back_image had a stray "$0" suffix (HTTP 400); trimmed to the real Coaster.png.

do $patch$
declare
  v_def text;
  v_new text;
  v_fn record;
begin
  for v_fn in select * from (values
    ('public.admin_get_collection(text,text)',
     $a$'coverImage', c.cover_image, 'category', c.category,$a$,
     $a$'coverImage', c.cover_image, 'backImage', c.back_image, 'backStyle', c.back_style, 'category', c.category,$a$),
    ('public.admin_save_collection(text,text,jsonb,jsonb)',
     $a$cover_image = nullif(btrim(p_col->>'coverImage'), ''),$a$,
     $a$cover_image = nullif(btrim(p_col->>'coverImage'), ''),
    back_image = case when p_col ? 'backImage' then nullif(btrim(coalesce(p_col->>'backImage', '')), '') else back_image end,
    back_style = case when not (p_col ? 'backStyle') then back_style when p_col->>'backStyle' = 'card' then 'card' else 'shape' end,$a$)
  ) as f(sig, old_txt, new_txt) loop
    v_def := pg_get_functiondef(v_fn.sig::regprocedure);
    v_new := replace(v_def, v_fn.old_txt, v_fn.new_txt);
    if v_new = v_def then raise exception 'patch anchor not found in %', v_fn.sig; end if;
    execute v_new;
  end loop;
end
$patch$;

update public.collections
   set back_image = 'https://rqhwzbrcgnpxtuaeoxml.supabase.co/storage/v1/object/public/app-assets/Coaster.png'
 where collection_id = 'gacha_261104_fcbce'
   and back_image = 'https://rqhwzbrcgnpxtuaeoxml.supabase.co/storage/v1/object/public/app-assets/Coaster.png$0';

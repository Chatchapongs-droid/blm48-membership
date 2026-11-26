-- Step 3a: run on the NEW project before restoring the schema.
-- Extensions the old project uses (pg_stat_statements and supabase_vault are on by default).
create extension if not exists pg_cron;
create extension if not exists pg_net;
create extension if not exists pgcrypto with schema extensions;
create extension if not exists "uuid-ossp" with schema extensions;
create extension if not exists plpgsql_check with schema extensions;

-- Storage policies (copied from the old project). The buckets themselves are created by
-- copy-storage.mjs through the Storage API.
drop policy if exists post_audio_public_insert on storage.objects;
create policy post_audio_public_insert on storage.objects for insert to anon with check (bucket_id = 'post-audio');
drop policy if exists post_images_public_insert on storage.objects;
create policy post_images_public_insert on storage.objects for insert to anon with check (bucket_id = 'post-images');
drop policy if exists profile_images_public_insert on storage.objects;
create policy profile_images_public_insert on storage.objects for insert to anon with check (bucket_id = 'profile-images');
drop policy if exists app_assets_public_insert on storage.objects;
create policy app_assets_public_insert on storage.objects for insert to anon with check (bucket_id = 'app-assets');
drop policy if exists app_assets_public_select on storage.objects;
create policy app_assets_public_select on storage.objects for select to anon using (bucket_id = 'app-assets');

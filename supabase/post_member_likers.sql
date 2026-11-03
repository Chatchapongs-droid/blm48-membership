-- 💖 โพสต์แฟนคลับ: รูปเมมเบอร์ที่กดใจโพสต์ (แสดงแทนยอดคุกกี้/ผู้ส่งของขวัญในโพสต์เมมเบอร์)
-- คืน [{ postId, count, likers: [{ username, name, img }] }] — likers สูงสุด 5 คน
create or replace function public.get_post_member_likers(p_post_ids text[])
returns jsonb
language sql
stable security definer
set search_path to 'public'
as $function$
  with ids as (
    select distinct unnest(coalesce(p_post_ids, '{}'::text[])) as post_id
  ),
  member_likes as (
    select l.post_id, u.username, coalesce(u.name, u.username) as name, u.profile_img as img,
           row_number() over (partition by l.post_id order by coalesce(u.name, u.username)) as rn,
           count(*) over (partition by l.post_id) as total
    from public.likes l
    join ids on ids.post_id = l.post_id
    join public.users u on u.username = l.username
    where lower(coalesce(u.role, '')) = 'member'
  ),
  agg as (
    select post_id, max(total) as total,
      jsonb_agg(jsonb_build_object('username', username, 'name', name, 'img', img) order by rn)
        filter (where rn <= 5) as likers
    from member_likes group by post_id
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'postId', i.post_id,
      'count', coalesce(a.total, 0),
      'likers', coalesce(a.likers, '[]'::jsonb)
    )), '[]'::jsonb)
  from ids i left join agg a on a.post_id = i.post_id;
$function$;

grant execute on function public.get_post_member_likers(text[]) to anon, authenticated;

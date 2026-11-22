-- _like_rules_tick (cron like_rules_drip, every 5 min) took ~2.3 s per run: to pick 2 random
-- likes it built every not-yet-liked post/comment for the 7 drip accounts by anti-joining the
-- WHOLE comment_likes (165k rows) and likes tables, and called is_month_closed() once per post.
--
-- Changes (candidate step only - everything after picking _lr is byte-for-byte the same):
--  - indexes on likes/comment_likes (username, ...) so only the drip accounts' rows are read
--    (also fixes the advisor's unindexed comment_likes_username_fkey)
--  - likes/comment_likes pre-filtered to the drip accounts (dl / dcl)
--  - closed-month check inlined against champ_of_the_month once, instead of a function per post
-- Verified before applying: identical candidate set (528 rows, 0 diff both ways) and identical
-- closed flag for every post.

create index if not exists comment_likes_username_comment_idx on public.comment_likes (username, comment_id);
create index if not exists likes_username_post_idx on public.likes (username, post_id);

CREATE OR REPLACE FUNCTION public._like_rules_tick(p_batch integer DEFAULT 15)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_ym text := to_char(now() at time zone 'Asia/Bangkok','YYYY-MM');
        v_n int;
begin
  drop table if exists _lr;
  create temp table _lr on commit drop as
  with drip(u) as (select unnest(array['48-480','00-480','00-7','00-70','00-35','00-135','00-108'])),
  closed_m as (select distinct lower(month_year) m from champ_of_the_month),
  ap as (
    select p.post_id, p.created_at, p.author, coalesce(p.post_type,'member') pt, u.name author_name,
           (coalesce(p.post_type,'member')='member' and lower(u.role)='member') is_member,
           exists (select 1 from closed_m where closed_m.m = lower(to_char(p.created_at at time zone 'Asia/Bangkok', 'FMMonth YYYY'))) closed
    from posts p join users u on u.username=p.author where p.created_at is not null),
  req as (
    select 'rule4_drip'::text src, a.u, ap.* from unnest(array['48-480','00-480']) a(u) cross join ap where ap.is_member
    union all
    select 'rule5_drip', a.u, ap.* from unnest(array['00-7','00-70','00-35','00-135']) a(u) cross join ap
      where ap.is_member and lower(ap.author_name)='emmy'
    union all
    select 'rule6_drip', '00-108', ap.* from ap where ap.is_member or ap.pt<>'member'),
  dl as materialized (select l.post_id, l.username from likes l where l.username in (select u from drip)),
  dcl as materialized (select l.comment_id, l.username from comment_likes l where l.username in (select u from drip)),
  cand as (
    select distinct on (kind, target_id, username) * from (
      select src, 'post'::text kind, req.post_id target_id, req.post_id, req.u username, req.author_name member_name, req.is_member, req.closed, req.created_at post_created
        from req where req.u<>req.author and not exists (select 1 from dl l where l.post_id=req.post_id and l.username=req.u)
      union all
      select src, 'comment', c.comment_id, req.post_id, req.u, req.author_name, req.is_member, req.closed, req.created_at
        from req join comments c on c.post_id=req.post_id
        where c.username<>req.u and not exists (select 1 from dcl l where l.comment_id=c.comment_id and l.username=req.u)) z)
  select cand.*, lower(u.role) role from cand join users u on u.username=cand.username
  order by random() limit p_batch;

  select count(*) into v_n from _lr;
  if v_n = 0 then return jsonb_build_object('liked', 0); end if;

  insert into likes (post_id, username) select post_id, username from _lr where kind='post' on conflict do nothing;
  insert into comment_likes (comment_id, username) select target_id, username from _lr where kind='comment' on conflict do nothing;
  update posts p set likes = (select count(*) from likes l where l.post_id=p.post_id) + coalesce(p.kept_likes,0) where p.post_id in (select post_id from _lr where kind='post');
  update comments c set likes = (select count(*) from comment_likes l where l.comment_id=c.comment_id) + coalesce(c.kept_likes,0) where c.comment_id in (select target_id from _lr where kind='comment');
  -- เมมเบอร์เจ้าของโพสต์: ยอดไลก์ / คุกกี้โบนัส (เดือนปิดแล้ว) / Ranking เดือนนี้
  update members m set total_like = coalesce(total_like,0) + x.n, cookie_bonus_total = coalesce(cookie_bonus_total,0) + 9*x.nc, updated_at = now()
    from (select lower(member_name) mn, count(*) n, count(*) filter (where closed) nc from _lr where is_member group by 1) x where lower(m.name)=x.mn;
  perform bump_ranking_monthly(member_name, v_ym, 9*count(*)) from _lr where is_member and not closed group by member_name;
  perform public._bump_daily_mission(l.username, 0, l.post_id, null)
    from _lr l where l.kind = 'post' and to_char(l.post_created at time zone 'Asia/Bangkok','YYYY-MM') = v_ym;
  -- คุกกี้ของโพสต์: ไลก์โพสต์เมมเบอร์ + ไลก์คอมเมนต์ทุกโพสต์ (เหมือน like_post / like_comment)
  update posts p set cookies = coalesce(p.cookies,0) + 9*x.n
    from (select post_id, count(*) n from _lr where is_member or kind='comment' group by 1) x where p.post_id=x.post_id;
  insert into fan_logs (username, member_name, amount) select username, member_name, 9 from _lr where lower(role) in ('user','ceo') and is_member;
  update users u set fan_cookies = coalesce(u.fan_cookies,0) + 9*x.n
    from (select username, count(*) n from _lr where lower(role) in ('user','ceo') and is_member group by 1) x where u.username=x.username;
  insert into oshi_auto_like_log (kind, target_id, post_id, username, member_name, month_closed, source)
    select kind, target_id, post_id, username, member_name, closed, src from _lr;
  drop table _lr;
  return jsonb_build_object('liked', v_n);
end; $function$;

-- Runs at :00/:05 collided with shop-open-notify, settle-member-campaigns and the every-minute
-- take-vote-checkpoints (some runs took 14-16 s). Same 5-minute rate, shifted 2 minutes off that beat.
select cron.alter_job(11, schedule := '2-59/5 * * * *');  -- like_rules_drip

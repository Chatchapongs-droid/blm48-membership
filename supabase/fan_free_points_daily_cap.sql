-- 2026-11-16: daily cap on FREE Fan Score Points (Emmy: "ใส่ลิมิตต่อวัน", "ลิมิตแค่แฟน").
-- Fans (role user/ceo) still get +9 Points for liking a member post, liking a comment on a member post,
-- and commenting/replying on a member post, but only for the first 30 such actions per Bangkok day,
-- and only the first comment per post per day counts.
-- Over the cap the action still works and the member side is unchanged (+9 Ranking/post cookies,
-- fan_logs / Top Fans unchanged) - only users.fan_cookies (Fan Score / Points / tier) is capped.
-- Unlike only takes back Points that the like actually paid; likes from before this change keep the
-- old behaviour (unlike = -9) because they have no award row.
-- Auto-like jobs (_like_rules_tick) are not capped.

create table if not exists public.fan_free_points (
  username   text not null,
  kind       text not null check (kind in ('post_like', 'comment_like', 'comment')),
  target_id  text not null,
  post_id    text,
  paid       boolean not null,
  created_at timestamptz not null default now(),
  primary key (username, kind, target_id)
);
create index if not exists fan_free_points_day_idx on public.fan_free_points (username, created_at) where paid;
alter table public.fan_free_points enable row level security;
-- no grants: only the SECURITY DEFINER functions below touch it

create or replace function public._fan_free_points_cap() returns integer
language sql immutable as $$ select 30 $$;

-- returns the Points to add (9 or 0) and records the award
create or replace function public._fan_free_award(p_username text, p_kind text, p_target text, p_post_id text)
returns numeric
language plpgsql security definer set search_path to 'public'
as $function$
declare
  v_day_start timestamptz := date_trunc('day', now() at time zone 'Asia/Bangkok') at time zone 'Asia/Bangkok';
  v_paid boolean;
begin
  perform pg_advisory_xact_lock(hashtext('fan_free_points:' || p_username));

  if exists (select 1 from public.fan_free_points where username = p_username and kind = p_kind and target_id = p_target) then
    return 0;  -- already recorded for this target (should not happen; be safe)
  end if;

  v_paid := (select count(*) from public.fan_free_points
              where username = p_username and paid and created_at >= v_day_start) < public._fan_free_points_cap();

  if v_paid and p_kind = 'comment' then
    v_paid := not exists (select 1 from public.fan_free_points
                           where username = p_username and kind = 'comment' and paid
                             and post_id = p_post_id and created_at >= v_day_start);
  end if;

  insert into public.fan_free_points (username, kind, target_id, post_id, paid)
    values (p_username, p_kind, p_target, p_post_id, v_paid);

  return case when v_paid then 9 else 0 end;
end;
$function$;

-- returns the Points to take back (9 or 0) when a like is removed
create or replace function public._fan_free_revoke(p_username text, p_kind text, p_target text)
returns numeric
language plpgsql security definer set search_path to 'public'
as $function$
declare
  v_paid boolean;
begin
  perform pg_advisory_xact_lock(hashtext('fan_free_points:' || p_username));
  delete from public.fan_free_points where username = p_username and kind = p_kind and target_id = p_target
    returning paid into v_paid;
  if not found then
    return 9;  -- like from before the cap existed: old behaviour
  end if;
  return case when v_paid then 9 else 0 end;
end;
$function$;

revoke all on function public._fan_free_award(text, text, text, text) from public, anon, authenticated;
revoke all on function public._fan_free_revoke(text, text, text) from public, anon, authenticated;

-- ---------------------------------------------------------------- like_post
CREATE OR REPLACE FUNCTION public.like_post(p_username text, p_post_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_post record;
  v_is_liked boolean;
  v_total_likes numeric;
  v_member_name text;
  v_year_month text;
  v_cookie_change numeric;
  v_actor_role text;
  v_post_cookies numeric;
  v_month_closed boolean;
  v_fan_pts numeric;
begin
  if p_username is null or p_post_id is null then
    return jsonb_build_object('status', 'error', 'message', 'ข้อมูลไม่ครบถ้วน');
  end if;

  select * into v_post from public.posts where post_id = p_post_id for update;
  if not found then
    return jsonb_build_object('status', 'error', 'message', 'ไม่พบโพสต์นี้ในระบบ');
  end if;

  select lower(role) into v_actor_role from public.users where username = p_username;

  if exists (select 1 from public.likes where post_id = p_post_id and username = p_username) then
    delete from public.likes where post_id = p_post_id and username = p_username;
    v_is_liked := false;
  else
    insert into public.likes (post_id, username) values (p_post_id, p_username);
    v_is_liked := true;
  end if;

  select count(*) + coalesce((select kept_likes from public.posts where post_id = p_post_id), 0) into v_total_likes from public.likes where post_id = p_post_id;
  update public.posts set likes = v_total_likes where post_id = p_post_id;

  v_post_cookies := coalesce(v_post.cookies, 0);

  if coalesce(v_post.post_type, 'member') = 'member' then
    select name into v_member_name from public.users where username = v_post.author;

    if v_member_name is not null and v_post.created_at is not null then
      update public.members set total_like = coalesce(total_like, 0) + (case when v_is_liked then 1 else -1 end), updated_at = now()
        where lower(name) = lower(v_member_name);

      v_cookie_change := case when v_is_liked then 9 else -9 end;
      v_month_closed := public.is_month_closed(v_post.created_at);

      if v_month_closed then
        update public.members set cookie_bonus_total = coalesce(cookie_bonus_total, 0) + v_cookie_change
          where lower(name) = lower(v_member_name);
      else
        v_year_month := to_char(now() at time zone 'Asia/Bangkok', 'YYYY-MM');
        insert into public.ranking_monthly (member_name, year_month, cookies)
          values (v_member_name, v_year_month, v_cookie_change)
          on conflict (member_name, year_month) do update set cookies = ranking_monthly.cookies + excluded.cookies;
      end if;

      update public.posts set cookies = coalesce(cookies, 0) + v_cookie_change where post_id = p_post_id
        returning cookies into v_post_cookies;

      if lower(v_actor_role) in ('user','ceo') then
        insert into public.fan_logs (username, member_name, amount) values (p_username, v_member_name, v_cookie_change);
        -- Fan Score Points: daily cap (see _fan_free_award)
        v_fan_pts := case when v_is_liked
                          then public._fan_free_award(p_username, 'post_like', p_post_id, p_post_id)
                          else -public._fan_free_revoke(p_username, 'post_like', p_post_id) end;
        if v_fan_pts <> 0 then
          update public.users set fan_cookies = coalesce(fan_cookies, 0) + v_fan_pts where username = p_username;
        end if;
      end if;
    end if;
  end if;

  if v_is_liked and v_post.created_at is not null
     and to_char(v_post.created_at at time zone 'Asia/Bangkok', 'YYYY-MM') = to_char(now() at time zone 'Asia/Bangkok', 'YYYY-MM') then
    perform public._bump_daily_mission(p_username, 0, p_post_id, null);
  end if;

  return jsonb_build_object(
    'status', 'success',
    'message', case when v_is_liked then 'กดใจให้เมมเบอร์แล้วน้า!' else 'ยกเลิกกดใจแล้วงับ' end,
    'likes', v_total_likes,
    'isLiked', v_is_liked,
    'postCookies', v_post_cookies,
    'fanPoints', v_fan_pts
  );
end;
$function$;

-- ---------------------------------------------------------------- like_comment
CREATE OR REPLACE FUNCTION public.like_comment(p_username text, p_comment_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_comment record;
  v_post record;
  v_is_liked boolean;
  v_total_likes numeric;
  v_member_name text;
  v_year_month text;
  v_actor_role text;
  v_cookie_change numeric;
  v_post_cookies numeric;
  v_month_closed boolean;
  v_fan_pts numeric;
begin
  if p_username is null or p_comment_id is null then
    return jsonb_build_object('status', 'error', 'message', 'ข้อมูลไม่ครบถ้วน');
  end if;

  select * into v_comment from public.comments where comment_id = p_comment_id for update;
  if not found then
    return jsonb_build_object('status', 'error', 'message', 'ไม่พบคอมเมนต์นี้ในระบบ');
  end if;

  select * into v_post from public.posts where post_id = v_comment.post_id;
  select lower(role) into v_actor_role from public.users where username = p_username;
  v_post_cookies := coalesce(v_post.cookies, 0);

  if exists (select 1 from public.comment_likes where comment_id = p_comment_id and username = p_username) then
    delete from public.comment_likes where comment_id = p_comment_id and username = p_username;
    v_is_liked := false;
  else
    insert into public.comment_likes (comment_id, username) values (p_comment_id, p_username);
    v_is_liked := true;
  end if;

  select count(*) + coalesce((select kept_likes from public.comments where comment_id = p_comment_id), 0) into v_total_likes from public.comment_likes where comment_id = p_comment_id;
  update public.comments set likes = v_total_likes where comment_id = p_comment_id;

  if v_post.post_id is not null and v_post.created_at is not null then
    select name into v_member_name from public.users where username = v_post.author;
    if v_member_name is not null then
      update public.members set total_like = coalesce(total_like, 0) + (case when v_is_liked then 1 else -1 end), updated_at = now()
        where lower(name) = lower(v_member_name);

      v_cookie_change := case when v_is_liked then 9 else -9 end;
      v_month_closed := public.is_month_closed(v_post.created_at);

      if v_month_closed then
        update public.members set cookie_bonus_total = coalesce(cookie_bonus_total, 0) + v_cookie_change
          where lower(name) = lower(v_member_name);
      else
        v_year_month := to_char(now() at time zone 'Asia/Bangkok', 'YYYY-MM');
        perform public.bump_ranking_monthly(v_member_name, v_year_month, v_cookie_change);
      end if;

      update public.posts set cookies = coalesce(cookies, 0) + v_cookie_change where post_id = v_post.post_id
        returning cookies into v_post_cookies;

      if lower(v_actor_role) in ('user','ceo') then
        insert into public.fan_logs (username, member_name, amount) values (p_username, v_member_name, v_cookie_change);
        -- Fan Score Points: daily cap (see _fan_free_award)
        v_fan_pts := case when v_is_liked
                          then public._fan_free_award(p_username, 'comment_like', p_comment_id, v_post.post_id)
                          else -public._fan_free_revoke(p_username, 'comment_like', p_comment_id) end;
        if v_fan_pts <> 0 then
          update public.users set fan_cookies = coalesce(fan_cookies, 0) + v_fan_pts where username = p_username;
        end if;
      end if;
    end if;
  end if;

  return jsonb_build_object(
    'status', 'success',
    'message', case when v_is_liked then 'กดใจคอมเมนต์แล้วน้า!' else 'ยกเลิกกดใจแล้วงับ' end,
    'likes', v_total_likes,
    'isLiked', v_is_liked,
    'postCookies', v_post_cookies,
    'fanPoints', v_fan_pts
  );
end;
$function$;

-- ---------------------------------------------------------------- add_comment (4-arg, the one the app calls)
CREATE OR REPLACE FUNCTION public.add_comment(p_username text, p_post_id text, p_text text, p_parent_comment_id text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_comment_id text;
  v_post record;
  v_parent record;
  v_parent_username text;
  v_top_parent_id text;
  v_member_name text;
  v_year_month text;
  v_actor_role text;
  v_post_cookies numeric;
  v_actor_name text;
  v_actor_avatar text;
  v_text_preview text;
  v_notified_usernames text[] := '{}';
  v_mentioned_name text;
  v_mentioned_username text;
  v_month_closed boolean;
  v_fan_pts numeric;
begin
  select * into v_post from public.posts where post_id = p_post_id;
  if p_post_id is null or not found then
    return jsonb_build_object('status', 'error', 'message', 'ไม่พบข้อมูล Post ID ที่จะคอมเมนต์');
  end if;
  if coalesce(trim(p_text), '') = '' then
    return jsonb_build_object('status', 'error', 'message', 'กรุณากรอกข้อความคอมเมนต์');
  end if;

  select lower(role) into v_actor_role from public.users where username = p_username;

  if coalesce(v_post.post_type, 'member') = 'fan' and v_actor_role = 'member' then
    return jsonb_build_object('status', 'error', 'message', 'สมาชิกไม่สามารถคอมเมนต์หรือรีพายโพสต์ของแฟนคลับได้ค่ะ');
  end if;

  v_top_parent_id := null;
  if p_parent_comment_id is not null then
    select * into v_parent from public.comments where comment_id = p_parent_comment_id and post_id = p_post_id;
    if not found then
      return jsonb_build_object('status', 'error', 'message', 'ไม่พบคอมเมนต์ที่จะตอบกลับ');
    end if;
    v_top_parent_id := coalesce(v_parent.parent_comment_id, v_parent.comment_id);
    v_parent_username := v_parent.username;
  end if;

  v_comment_id := 'CMT_' || floor(extract(epoch from clock_timestamp()) * 1000)::bigint::text;

  insert into public.comments (comment_id, post_id, username, text, parent_comment_id)
  values (v_comment_id, p_post_id, p_username, trim(p_text), v_top_parent_id);

  v_post_cookies := coalesce(v_post.cookies, 0);

  if coalesce(v_post.post_type, 'member') = 'member' and v_post.created_at is not null then
    select name into v_member_name from public.users where username = v_post.author;
    if v_member_name is not null then
      v_month_closed := public.is_month_closed(v_post.created_at);

      if v_month_closed then
        update public.members set cookie_bonus_total = coalesce(cookie_bonus_total, 0) + 9
          where lower(name) = lower(v_member_name);
      else
        v_year_month := to_char(now() at time zone 'Asia/Bangkok', 'YYYY-MM');
        perform public.bump_ranking_monthly(v_member_name, v_year_month, 9);
      end if;

      update public.posts set cookies = coalesce(cookies, 0) + 9 where post_id = p_post_id
        returning cookies into v_post_cookies;

      if lower(v_actor_role) in ('user','ceo') then
        insert into public.fan_logs (username, member_name, amount) values (p_username, v_member_name, 9);
        -- Fan Score Points: daily cap, first comment per post per day (see _fan_free_award)
        v_fan_pts := public._fan_free_award(p_username, 'comment', v_comment_id, p_post_id);
        if v_fan_pts <> 0 then
          update public.users set fan_cookies = coalesce(fan_cookies, 0) + v_fan_pts where username = p_username;
        end if;
      end if;
    end if;
  end if;

  if v_post.created_at is not null
     and to_char(v_post.created_at at time zone 'Asia/Bangkok', 'YYYY-MM') = to_char(now() at time zone 'Asia/Bangkok', 'YYYY-MM') then
    perform public._bump_daily_mission(p_username, 0, null, p_post_id);
  end if;

  select name, profile_img into v_actor_name, v_actor_avatar from public.users where username = p_username;
  v_text_preview := left(trim(p_text), 60) || (case when length(trim(p_text)) > 60 then '…' else '' end);

  if v_parent_username is not null and v_parent_username <> p_username then
    insert into public.notifications (recipient_username, writer, action, avatar, role, notif_type, post_id, comment_id)
    values (v_parent_username, coalesce(v_actor_name, p_username), 'ตอบกลับคอมเมนต์ของคุณ: "' || v_text_preview || '"', v_actor_avatar, coalesce(v_actor_role, 'user'), 'reply', p_post_id, v_comment_id);
    v_notified_usernames := array_append(v_notified_usernames, v_parent_username);
  elsif p_parent_comment_id is null and v_post.author is not null and v_post.author <> p_username then
    insert into public.notifications (recipient_username, writer, action, avatar, role, notif_type, post_id, comment_id)
    values (v_post.author, coalesce(v_actor_name, p_username), 'แสดงความคิดเห็นในโพสต์ของคุณ: "' || v_text_preview || '"', v_actor_avatar, coalesce(v_actor_role, 'user'), 'comment', p_post_id, v_comment_id);
    v_notified_usernames := array_append(v_notified_usernames, v_post.author);
  end if;

  for v_mentioned_name in select * from public._extract_mentioned_members(p_text) loop
    select username into v_mentioned_username from public.users
      where lower(role) = 'member' and lower(name) = lower(v_mentioned_name) limit 1;
    if v_mentioned_username is not null and v_mentioned_username <> p_username
       and not (v_mentioned_username = any(v_notified_usernames)) then
      insert into public.notifications (recipient_username, writer, action, avatar, role, notif_type, post_id, comment_id)
      values (v_mentioned_username, coalesce(v_actor_name, p_username), 'แท็กคุณในคอมเมนต์: "' || v_text_preview || '"', v_actor_avatar, coalesce(v_actor_role, 'user'), 'mention', p_post_id, v_comment_id);
      v_notified_usernames := array_append(v_notified_usernames, v_mentioned_username);
    end if;
  end loop;

  return jsonb_build_object('status', 'success', 'message', 'ส่งคอมเมนต์เรียบร้อยแล้วงับ!', 'commentId', v_comment_id, 'parentCommentId', v_top_parent_id, 'postCookies', v_post_cookies, 'fanPoints', v_fan_pts);
end;
$function$;

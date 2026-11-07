-- 2026-11-07: Campaign Top Supporters (campaign_supporters.html) = same rules as Ranking (ranking_monthly)
-- Applied to Supabase as migration "campaign_supporters_match_ranking".
-- Display only: refunds / Tier still come from campaign_supports.

create index if not exists wallet_logs_give_cookie_target_idx on public.wallet_logs (lower(target), created_at) where action = 'Give Cookie';

-- Cookie throws/gifts by every role (incl. the member herself) from the 1st of the campaign month,
-- + 9 per like / comment / comment-like on the member's posts created in the campaign month.
create or replace function public._campaign_supporter_rows(c member_campaigns)
 returns table(username text, amount numeric, created_at timestamp with time zone)
 language sql stable security definer set search_path to 'public'
as $function$
  with b as (
    select (to_date(c.year_month || '-01', 'YYYY-MM-DD')::timestamp at time zone 'Asia/Bangkok') as ms, c.end_at as me
  ),
  mp as (
    select p.post_id, p.created_at
      from public.posts p join public.users au on au.username = p.author, b
     where lower(au.role) = 'member' and lower(au.name) = lower(c.member_name)
       and coalesce(p.post_type, 'member') = 'member'
       and p.created_at >= b.ms and p.created_at < b.me
  )
  select public.username_of(w.wallet_code), w.amount, w.created_at
    from public.wallet_logs w, b
   where w.action = 'Give Cookie' and lower(w.target) = lower(c.member_name)
     and w.created_at >= b.ms and w.created_at < b.me
  union all
  select l.username, 9::numeric, coalesce(l.created_at, mp.created_at)
    from mp join public.likes l on l.post_id = mp.post_id
  union all
  select cm.username, 9::numeric, cm.created_at
    from mp join public.comments cm on cm.post_id = mp.post_id
  union all
  select cl.username, 9::numeric, coalesce(cl.created_at, cm.created_at)
    from mp join public.comments cm on cm.post_id = mp.post_id
            join public.comment_likes cl on cl.comment_id = cm.comment_id
$function$;

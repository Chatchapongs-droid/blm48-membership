-- 2026-11-16: reverse every MEMBER Point Shop exchange before member prices change.
-- Member Score is computed live and point_exchanges is subtracted from it,
-- so deleting the rows gives the Points back. The Tokens received are taken back.
-- Affected: 00-108 (60,000 P / 390 Token), 00-109 (420,000 P / 650 Token), 00-110 (200,000 P / 260 Token)
begin;

with rev as (
  select username, wallet_code, sum(points) pts,
         sum(reward_amount) filter (where reward_kind = 'token') tok,
         sum(reward_amount) filter (where reward_kind <> 'token') ck
  from public.point_exchanges where score_kind = 'member'
  group by username, wallet_code
), upd as (
  update public.users u
     set token = u.token - coalesce(rev.tok, 0),
         cookie = u.cookie - coalesce(rev.ck, 0),
         updated_at = now()
    from rev where u.username = rev.username
  returning u.username
)
insert into public.wallet_logs (wallet_code, action, target, amount)
select wallet_code, 'Point Exchange คืน',
       'คืน ' || to_char(pts, 'FM999,999,999') || ' Points - Token', -tok
  from rev where coalesce(tok, 0) > 0;

delete from public.point_exchanges where score_kind = 'member';

commit;

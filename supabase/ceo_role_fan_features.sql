-- 2026-11-16: Role CEO = full Admin access (via is_admin_or_ceo / is_admin)
-- AND still counted as a fan ('user') for Fan Score, likes/comment cookies,
-- Daily Mission, monthly Token bonus, campaigns, fan posts, per-role codes.
-- Taylor (00-1) promoted to CEO.

do $$
declare r record; v_new text;
begin
  for r in
    select p.oid, pg_get_functiondef(p.oid) d
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.prokind = 'f'
      and p.proname in ('_daily_mission_targets','_like_rules_tick','add_comment','admin_get_dashboard',
        'admin_get_dashboard_stats','auto_open_birthday_campaigns','create_post','get_daily_missions',
        'give_cookie','like_comment','like_post','open_member_campaign','send_member_gift',
        'claim_daily_mission_reward','admin_lookup_user','admin_transfer_wallet')
  loop
    v_new := regexp_replace(regexp_replace(regexp_replace(r.d,
      $re$((?:lower\()?[a-z_.]*role\)?)\s*=\s*'user'$re$, $rp$lower(\1) in ('user','ceo')$rp$, 'gi'),
      $re$((?:lower\()?[a-z_.]*role\)?)\s*<>\s*'user'$re$, $rp$lower(\1) not in ('user','ceo')$rp$, 'gi'),
      $re$((?:lower\()?[a-z_.]*role\)?)\s+(not\s+)?in\s*\(\s*'user',\s*'member'\s*\)$re$, $rp$lower(\1) \2in ('user','member','ceo')$rp$, 'gi');
    if v_new <> r.d then execute v_new; end if;
  end loop;

  -- per-role redeem codes: CEO gets the 'user' rewards
  select pg_get_functiondef('public.redeem_code'::regproc) into v_new;
  v_new := replace(v_new,
    $s$v_actor_role := lower(coalesce(v_user.role, 'user'));$s$,
    $s$v_actor_role := lower(coalesce(v_user.role, 'user'));
  if v_actor_role = 'ceo' then v_actor_role := 'user'; end if;$s$);
  execute v_new;
end $$;

update public.users set role = 'CEO', is_admin = true, updated_at = now() where username = '00-1';

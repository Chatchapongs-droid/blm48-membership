-- 2026-11-13: remove emoji from user-facing messages/notification text produced by RPCs.
-- Applied to Supabase as migration strip_emoji_from_server_messages_2026_11_13.
-- Re-creates each function from its own definition with emoji (and the space before it) removed.
-- Affected: add_comment, admin_set_preorder_order_status, admin_transfer_wallet, buy_direct_item,
-- buy_preorder, check_shop_open_notifications, claim_daily_mission_reward, claim_login_monthly_reward,
-- create_champ_thanks_post, create_post, edit_comment, like_comment, like_post, redeem_code,
-- settle_major_vote_refunds, use_login_rescue.
-- admin_get_dashboard / give_cookie only have emoji in code comments -> left as is.
-- Notifications already saved before this date still contain emoji (left unchanged on purpose).
-- Rule going forward: don't put emoji in new RPC messages.
do $$
declare r record; v_def text; v_new text;
begin
  for r in
    select p.oid, p.oid::regprocedure::text sig
    from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.prosrc ~ '[\U0001F300-\U0001FAFF☀-➿]'
      and p.proname not in ('admin_get_dashboard', 'give_cookie')
  loop
    v_def := pg_get_functiondef(r.oid);
    v_new := regexp_replace(v_def, '\s?[\U0001F300-\U0001FAFF☀-➿]️?', '', 'g');
    if v_new <> v_def then
      execute v_new;
      raise notice 'updated %', r.sig;
    end if;
  end loop;
end $$;

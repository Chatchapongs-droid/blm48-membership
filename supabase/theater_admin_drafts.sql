-- 🎭 Admins see draft events on the fan-side Theaters pages (2026-11-03, migration theater_admin_drafts)
-- get_theater_events lists drafts too when is_admin_or_ceo(p_username), and returns 'status' per event;
-- get_theater_event opens a draft for admins. Booking stays blocked: theater_book requires 'published'.
do $patch$
declare
  v_def text;
  v_new text;
  v_fn record;
begin
  for v_fn in select * from (values
    ('public.get_theater_events(text)',
     $a$'platform', e.platform, 'venue', e.venue,$a$,
     $a$'platform', e.platform, 'venue', e.venue, 'status', e.status,$a$),
    ('public.get_theater_events(text)',
     $a$where e.status = 'published' and e.event_date >= public.theater_today()$a$,
     $a$where (e.status = 'published' or (e.status = 'draft' and public.is_admin_or_ceo(p_username)))
          and e.event_date >= public.theater_today()$a$),
    ('public.get_theater_event(text,bigint)',
     $a$where id = p_event_id and status <> 'draft';$a$,
     $a$where id = p_event_id and (status <> 'draft' or public.is_admin_or_ceo(p_username));$a$)
  ) as f(sig, old_txt, new_txt) loop
    v_def := pg_get_functiondef(v_fn.sig::regprocedure);
    v_new := replace(v_def, v_fn.old_txt, v_fn.new_txt);
    if v_new = v_def then raise exception 'patch anchor not found in %', v_fn.sig; end if;
    execute v_new;
  end loop;
end
$patch$;

-- 2026-11-13: Point Shop opening moved up to tonight 22:08 Bangkok (was 2026-11-14 00:00).
-- Notification job moved to 22:09 Bangkok = 15:09 GMT (cron runs in GMT); it still removes itself after sending.
CREATE OR REPLACE FUNCTION public._point_shop_open_at()
 RETURNS timestamp with time zone
 LANGUAGE sql
 IMMUTABLE
AS $function$ select timestamptz '2026-11-13 22:08:00+07' $function$;

select cron.schedule('point-shop-open-notify', '9 15 13 11 *', 'select public.notify_point_shop_open();');

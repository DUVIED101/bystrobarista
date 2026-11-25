-- Tests for migration 143 (engagement push queue). Run through run.sh.
-- The whole file is one transaction that is rolled back at the end.
-- Reference moment: 2026-03-10 12:00 MSK (a Tuesday, outside quiet hours);
-- rows are queued with explicit send_after values because the session clock
-- is unrelated to it.
BEGIN;

-- ---------------------------------------------------------------------------
-- notifications_kind_check
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_user UUID := test.make_user('kind-check@test.local');
  v_bogus_rejected BOOLEAN := false;
BEGIN
  INSERT INTO public.notifications (user_id, kind, title, body)
  VALUES (v_user, 'new_job_nearby', 't', 'b');

  BEGIN
    INSERT INTO public.notifications (user_id, kind, title, body)
    VALUES (v_user, 'bogus', 't', 'b');
  EXCEPTION WHEN check_violation THEN
    v_bogus_rejected := true;
  END;
  ASSERT v_bogus_rejected, 'bogus kind must be rejected';
  RAISE NOTICE 'ok: notifications_kind_check accepts new_job_nearby and rejects bogus';
END $$;

-- ---------------------------------------------------------------------------
-- Flags and readers
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  ASSERT app_internal.engagement_push_mode() = 'off', 'default mode must be off';
  ASSERT (app_internal.engagement_push_config()->>'quiet_start_hour')::INT = 21;
  ASSERT (app_internal.engagement_push_config()->>'batch_size')::INT = 200;

  UPDATE public.feature_flags SET value = '"nonsense"' WHERE key = 'engagement_push_mode';
  ASSERT app_internal.engagement_push_mode() = 'off', 'unknown mode must read as off';

  UPDATE public.feature_flags SET value = '{"mode":"on"}' WHERE key = 'engagement_push_mode';
  ASSERT app_internal.engagement_push_mode() = 'off', 'object mode value must read as off';

  UPDATE public.feature_flags SET value = '{"batch_size": 5}' WHERE key = 'engagement_push_config';
  ASSERT (app_internal.engagement_push_config()->>'batch_size')::INT = 5;
  ASSERT (app_internal.engagement_push_config()->>'quiet_end_hour')::INT = 10, 'missing keys fall back to defaults';
  UPDATE public.feature_flags SET value = '{}' WHERE key = 'engagement_push_config';

  UPDATE public.feature_flags SET value = '"off"' WHERE key = 'engagement_push_mode';
  RAISE NOTICE 'ok: engagement_push_mode / engagement_push_config readers';
END $$;

-- ---------------------------------------------------------------------------
-- enqueue: mode off, dedupe, data coercion
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_user UUID := test.make_user('enqueue@test.local');
  -- Far in the future so these rows never become due in later blocks.
  v_base TIMESTAMPTZ := '2099-01-01 12:00:00+03';
  v_data JSONB;
  v_nested_rejected BOOLEAN := false;
BEGIN
  UPDATE public.feature_flags SET value = '"off"' WHERE key = 'engagement_push_mode';
  ASSERT app_internal.enqueue_engagement_push(v_user, 'app_update', 't', 'b', '{}', 'off:1', v_base) = false,
    'enqueue must return false in mode off';
  ASSERT (SELECT count(*) FROM app_internal.engagement_pushes WHERE user_id = v_user) = 0,
    'mode off must insert nothing';

  UPDATE public.feature_flags SET value = '"on"' WHERE key = 'engagement_push_mode';
  ASSERT app_internal.enqueue_engagement_push(v_user, 'app_update', 't', 'b', '{"n": 5, "ok": true, "s": "x", "nil": null}', 'dedupe:1', v_base);
  ASSERT app_internal.enqueue_engagement_push(v_user, 'app_update', 't2', 'b2', '{}', 'dedupe:1', v_base) = false,
    'second enqueue with the same dedupe_key must return false';
  ASSERT (SELECT count(*) FROM app_internal.engagement_pushes WHERE user_id = v_user) = 1,
    'dedupe must keep a single row';

  SELECT data INTO v_data FROM app_internal.engagement_pushes WHERE dedupe_key = 'dedupe:1';
  ASSERT v_data = '{"n": "5", "ok": "true", "s": "x"}'::jsonb, 'data values must be coerced to strings, nulls dropped: ' || v_data::TEXT;

  BEGIN
    PERFORM app_internal.enqueue_engagement_push(v_user, 'app_update', 't', 'b', '{"o": {"a": 1}}', 'nested:1', v_base);
  EXCEPTION WHEN invalid_parameter_value THEN
    v_nested_rejected := true;
  END;
  ASSERT v_nested_rejected, 'nested data values must raise 22023';
  RAISE NOTICE 'ok: enqueue mode off / dedupe / data coercion';
END $$;

-- ---------------------------------------------------------------------------
-- process: happy path at 12:00 MSK
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_user UUID := test.make_user('happy@test.local');
  v_base TIMESTAMPTZ := '2026-03-10 12:00:00+03';
  v_result RECORD;
  v_push RECORD;
  v_dispatch RECORD;
BEGIN
  UPDATE public.feature_flags SET value = '"on"' WHERE key = 'engagement_push_mode';
  PERFORM app_internal.enqueue_engagement_push(v_user, 'new_job_nearby', 'Новая смена', 'Рядом с метро', '{"jobId": "job-1"}', 'happy:1', v_base - INTERVAL '1 hour');

  SELECT * INTO v_result FROM app_internal.process_engagement_pushes(v_base);
  ASSERT (v_result.sent, v_result.skipped, v_result.deferred) = (1, 0, 0), format('expected (1,0,0), got %s', v_result);

  SELECT * INTO v_push FROM app_internal.engagement_pushes WHERE dedupe_key = 'happy:1';
  ASSERT v_push.sent_at = v_base AND v_push.skipped_reason IS NULL, 'sent_at must equal p_now';

  ASSERT (SELECT count(*) FROM public.notifications WHERE user_id = v_user AND kind = 'new_job_nearby') = 1,
    'one notifications row expected';
  ASSERT (SELECT data FROM public.notifications WHERE user_id = v_user) = '{"jobId": "job-1"}'::jsonb;

  SELECT * INTO v_dispatch FROM app_internal.apns_dispatch_log WHERE recipient_id = v_user;
  ASSERT v_dispatch.kind = 'new_job_nearby', 'dispatch kind';
  ASSERT v_dispatch.payload->'data' = '{"jobId": "job-1", "kind": "new_job_nearby"}'::jsonb,
    'dispatched data must keep values and carry kind: ' || (v_dispatch.payload->'data')::TEXT;
  ASSERT v_dispatch.payload->>'title' = 'Новая смена';

  -- A second tick finds nothing.
  SELECT * INTO v_result FROM app_internal.process_engagement_pushes(v_base + INTERVAL '5 minutes');
  ASSERT (v_result.sent, v_result.skipped, v_result.deferred) = (0, 0, 0);
  RAISE NOTICE 'ok: process sends at 12:00 MSK and dispatches the push';
END $$;

-- ---------------------------------------------------------------------------
-- quiet hours
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_user UUID := test.make_user('quiet@test.local');
  v_result RECORD;
BEGIN
  UPDATE public.feature_flags SET value = '"on"' WHERE key = 'engagement_push_mode';

  PERFORM app_internal.enqueue_engagement_push(v_user, 'app_update', 't', 'b', '{}', 'quiet:late', '2026-03-10 22:00:00+03');
  SELECT * INTO v_result FROM app_internal.process_engagement_pushes('2026-03-10 22:30:00+03');
  ASSERT (v_result.sent, v_result.skipped, v_result.deferred) = (0, 0, 1), format('22:30: expected (0,0,1), got %s', v_result);
  ASSERT (SELECT send_after FROM app_internal.engagement_pushes WHERE dedupe_key = 'quiet:late')
         = '2026-03-11 10:00:00+03'::timestamptz, '22:30 MSK must defer to next day 10:00 MSK';
  ASSERT (SELECT sent_at IS NULL AND skipped_reason IS NULL FROM app_internal.engagement_pushes WHERE dedupe_key = 'quiet:late');

  PERFORM app_internal.enqueue_engagement_push(v_user, 'app_update', 't', 'b', '{}', 'quiet:early', '2026-03-10 08:00:00+03');
  SELECT * INTO v_result FROM app_internal.process_engagement_pushes('2026-03-10 09:00:00+03');
  ASSERT (v_result.sent, v_result.skipped, v_result.deferred) = (0, 0, 1), format('09:00: expected (0,0,1), got %s', v_result);
  ASSERT (SELECT send_after FROM app_internal.engagement_pushes WHERE dedupe_key = 'quiet:early')
         = '2026-03-10 10:00:00+03'::timestamptz, '09:00 MSK must defer to same day 10:00 MSK';

  -- Boundaries: 21:00 is quiet, 10:00 is not. Session time zone must not matter.
  PERFORM set_config('TimeZone', 'America/New_York', true);
  SELECT * INTO v_result FROM app_internal.process_engagement_pushes('2026-03-10 21:00:00+03');
  ASSERT (v_result.sent, v_result.skipped, v_result.deferred) = (0, 0, 1), format('21:00: expected (0,0,1), got %s', v_result);
  ASSERT (SELECT send_after FROM app_internal.engagement_pushes WHERE dedupe_key = 'quiet:early')
         = '2026-03-11 10:00:00+03'::timestamptz, '21:00 MSK must defer to next day 10:00 MSK';

  SELECT * INTO v_result FROM app_internal.process_engagement_pushes('2026-03-11 10:00:00+03');
  ASSERT (v_result.sent, v_result.skipped, v_result.deferred) = (2, 0, 0), format('10:00: expected (2,0,0), got %s', v_result);
  PERFORM set_config('TimeZone', 'UTC', true);
  RAISE NOTICE 'ok: quiet hours defer to 10:00 MSK';
END $$;

-- ---------------------------------------------------------------------------
-- marketing limits
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_user UUID := test.make_user('marketing-daily@test.local');
  v_weekly UUID := test.make_user('marketing-weekly@test.local');
  v_base TIMESTAMPTZ := '2026-03-10 12:00:00+03';
  v_result RECORD;
BEGIN
  UPDATE public.feature_flags SET value = '"on"' WHERE key = 'engagement_push_mode';

  PERFORM app_internal.enqueue_engagement_push(v_user, 'weekly_digest', 't', 'b', '{}', 'mk:digest', v_base - INTERVAL '2 hours');
  PERFORM app_internal.enqueue_engagement_push(v_user, 'recurring_broadcast', 't', 'b', '{}', 'mk:broadcast', v_base - INTERVAL '1 hour');
  SELECT * INTO v_result FROM app_internal.process_engagement_pushes(v_base);
  ASSERT (v_result.sent, v_result.skipped, v_result.deferred) = (1, 1, 0), format('daily: expected (1,1,0), got %s', v_result);
  ASSERT (SELECT sent_at FROM app_internal.engagement_pushes WHERE dedupe_key = 'mk:digest') = v_base;
  ASSERT (SELECT skipped_reason FROM app_internal.engagement_pushes WHERE dedupe_key = 'mk:broadcast') = 'daily_limit';

  -- Three marketing pushes sent on different days within the last week.
  INSERT INTO app_internal.engagement_pushes (user_id, kind, title, body, dedupe_key, send_after, sent_at)
  VALUES
    (v_weekly, 'recurring_broadcast', 't', 'b', 'wk:1', v_base - INTERVAL '6 days', v_base - INTERVAL '6 days'),
    (v_weekly, 'weekly_digest',       't', 'b', 'wk:2', v_base - INTERVAL '4 days', v_base - INTERVAL '4 days'),
    (v_weekly, 'profile_hidden',      't', 'b', 'wk:3', v_base - INTERVAL '2 days', v_base - INTERVAL '2 days');
  PERFORM app_internal.enqueue_engagement_push(v_weekly, 'recurring_broadcast', 't', 'b', '{}', 'wk:4', v_base - INTERVAL '1 hour');
  SELECT * INTO v_result FROM app_internal.process_engagement_pushes(v_base);
  ASSERT (v_result.sent, v_result.skipped, v_result.deferred) = (0, 1, 0), format('weekly: expected (0,1,0), got %s', v_result);
  ASSERT (SELECT skipped_reason FROM app_internal.engagement_pushes WHERE dedupe_key = 'wk:4') = 'weekly_limit';

  -- Eight days later the window has rolled over.
  PERFORM app_internal.enqueue_engagement_push(v_weekly, 'recurring_broadcast', 't', 'b', '{}', 'wk:5', v_base + INTERVAL '8 days');
  SELECT * INTO v_result FROM app_internal.process_engagement_pushes(v_base + INTERVAL '8 days');
  ASSERT (v_result.sent, v_result.skipped, v_result.deferred) = (1, 0, 0), format('rollover: expected (1,0,0), got %s', v_result);
  RAISE NOTICE 'ok: marketing daily / weekly limits';
END $$;

-- ---------------------------------------------------------------------------
-- new_job_nearby and reminder daily limits
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_nearby UUID := test.make_user('nearby@test.local');
  v_remind UUID := test.make_user('remind@test.local', 'business');
  v_base TIMESTAMPTZ := '2026-03-10 12:00:00+03';
  v_result RECORD;
BEGIN
  UPDATE public.feature_flags SET value = '"on"' WHERE key = 'engagement_push_mode';

  PERFORM app_internal.enqueue_engagement_push(v_nearby, 'new_job_nearby', 't', 'b', '{}', 'nb:1', v_base - INTERVAL '2 hours');
  PERFORM app_internal.enqueue_engagement_push(v_nearby, 'new_job_nearby', 't', 'b', '{}', 'nb:2', v_base - INTERVAL '1 hour');
  -- An unlimited kind for the same user is unaffected.
  PERFORM app_internal.enqueue_engagement_push(v_nearby, 'application_expired', 't', 'b', '{}', 'nb:expired', v_base - INTERVAL '30 minutes');
  PERFORM app_internal.enqueue_engagement_push(v_remind, 'application_reminder', 't', 'b', '{}', 'rm:1', v_base - INTERVAL '2 hours');
  PERFORM app_internal.enqueue_engagement_push(v_remind, 'job_offer_reminder', 't', 'b', '{}', 'rm:2', v_base - INTERVAL '1 hour');

  SELECT * INTO v_result FROM app_internal.process_engagement_pushes(v_base);
  ASSERT (v_result.sent, v_result.skipped, v_result.deferred) = (3, 2, 0), format('expected (3,2,0), got %s', v_result);
  ASSERT (SELECT sent_at FROM app_internal.engagement_pushes WHERE dedupe_key = 'nb:1') = v_base;
  ASSERT (SELECT skipped_reason FROM app_internal.engagement_pushes WHERE dedupe_key = 'nb:2') = 'daily_limit';
  ASSERT (SELECT sent_at FROM app_internal.engagement_pushes WHERE dedupe_key = 'nb:expired') = v_base;
  ASSERT (SELECT sent_at FROM app_internal.engagement_pushes WHERE dedupe_key = 'rm:1') = v_base;
  ASSERT (SELECT skipped_reason FROM app_internal.engagement_pushes WHERE dedupe_key = 'rm:2') = 'daily_limit';

  -- Next day the nearby push goes out again.
  PERFORM app_internal.enqueue_engagement_push(v_nearby, 'new_job_nearby', 't', 'b', '{}', 'nb:3', v_base + INTERVAL '1 day');
  SELECT * INTO v_result FROM app_internal.process_engagement_pushes(v_base + INTERVAL '1 day');
  ASSERT (v_result.sent, v_result.skipped, v_result.deferred) = (1, 0, 0), format('next day: expected (1,0,0), got %s', v_result);
  RAISE NOTICE 'ok: new_job_nearby / reminder daily limits';
END $$;

-- ---------------------------------------------------------------------------
-- preferences gate
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_user UUID := test.make_user('prefs@test.local');
  v_base TIMESTAMPTZ := '2026-03-10 12:00:00+03';
  v_result RECORD;
BEGIN
  UPDATE public.feature_flags SET value = '"on"' WHERE key = 'engagement_push_mode';
  INSERT INTO public.notification_preferences (user_id, new_job_nearby, response_reminders, weekly_digest, product_news)
  VALUES (v_user, false, false, false, false);

  PERFORM app_internal.enqueue_engagement_push(v_user, 'recurring_broadcast',  't', 'b', '{}', 'pf:broadcast', v_base - INTERVAL '1 hour');
  PERFORM app_internal.enqueue_engagement_push(v_user, 'profile_hidden',       't', 'b', '{}', 'pf:hidden',    v_base - INTERVAL '1 hour');
  PERFORM app_internal.enqueue_engagement_push(v_user, 'new_job_nearby',       't', 'b', '{}', 'pf:nearby',    v_base - INTERVAL '1 hour');
  PERFORM app_internal.enqueue_engagement_push(v_user, 'application_reminder', 't', 'b', '{}', 'pf:app-rem',   v_base - INTERVAL '1 hour');
  PERFORM app_internal.enqueue_engagement_push(v_user, 'job_offer_reminder',   't', 'b', '{}', 'pf:offer-rem', v_base - INTERVAL '1 hour');
  PERFORM app_internal.enqueue_engagement_push(v_user, 'weekly_digest',        't', 'b', '{}', 'pf:digest',    v_base - INTERVAL '1 hour');
  PERFORM app_internal.enqueue_engagement_push(v_user, 'app_update',           't', 'b', '{}', 'pf:update',    v_base - INTERVAL '1 hour');
  PERFORM app_internal.enqueue_engagement_push(v_user, 'application_expired',  't', 'b', '{}', 'pf:app-exp',   v_base - INTERVAL '1 hour');
  PERFORM app_internal.enqueue_engagement_push(v_user, 'job_offer_expired',    't', 'b', '{}', 'pf:offer-exp', v_base - INTERVAL '1 hour');

  SELECT * INTO v_result FROM app_internal.process_engagement_pushes(v_base);
  ASSERT (v_result.sent, v_result.skipped, v_result.deferred) = (3, 6, 0), format('expected (3,6,0), got %s', v_result);
  ASSERT (SELECT array_agg(dedupe_key ORDER BY dedupe_key) FROM app_internal.engagement_pushes
          WHERE user_id = v_user AND skipped_reason = 'pref_disabled')
         = ARRAY['pf:app-rem', 'pf:broadcast', 'pf:digest', 'pf:hidden', 'pf:nearby', 'pf:offer-rem'],
    'every gated kind must be skipped as pref_disabled';
  ASSERT (SELECT array_agg(dedupe_key ORDER BY dedupe_key) FROM app_internal.engagement_pushes
          WHERE user_id = v_user AND sent_at IS NOT NULL)
         = ARRAY['pf:app-exp', 'pf:offer-exp', 'pf:update'],
    'ungated kinds must go out with every preference off';

  -- Re-enabling product_news lets recurring_broadcast through again.
  UPDATE public.notification_preferences SET product_news = true WHERE user_id = v_user;
  PERFORM app_internal.enqueue_engagement_push(v_user, 'recurring_broadcast', 't', 'b', '{}', 'pf:broadcast2', v_base + INTERVAL '1 day');
  SELECT * INTO v_result FROM app_internal.process_engagement_pushes(v_base + INTERVAL '1 day');
  ASSERT (v_result.sent, v_result.skipped, v_result.deferred) = (1, 0, 0), format('re-enabled: expected (1,0,0), got %s', v_result);
  RAISE NOTICE 'ok: preferences gate per kind, ungated kinds always go out';
END $$;

-- ---------------------------------------------------------------------------
-- recipient state and modes
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_banned UUID := test.make_user('banned@test.local');
  v_inactive UUID := test.make_user('inactive@test.local');
  v_admin UUID := test.make_user('admin-skip@test.local', 'barista', true);
  v_base TIMESTAMPTZ := '2026-03-10 12:00:00+03';
  v_result RECORD;
BEGIN
  UPDATE public.feature_flags SET value = '"on"' WHERE key = 'engagement_push_mode';
  UPDATE public.users SET banned_at = v_base - INTERVAL '1 day' WHERE id = v_banned;
  UPDATE public.users SET is_active = false WHERE id = v_inactive;

  PERFORM app_internal.enqueue_engagement_push(v_banned,   'app_update', 't', 'b', '{}', 'st:banned',   v_base - INTERVAL '1 hour');
  PERFORM app_internal.enqueue_engagement_push(v_inactive, 'app_update', 't', 'b', '{}', 'st:inactive', v_base - INTERVAL '1 hour');
  PERFORM app_internal.enqueue_engagement_push(v_admin,    'app_update', 't', 'b', '{}', 'st:admin',    v_base - INTERVAL '1 hour');

  SELECT * INTO v_result FROM app_internal.process_engagement_pushes(v_base);
  ASSERT (v_result.sent, v_result.skipped, v_result.deferred) = (0, 3, 0), format('expected (0,3,0), got %s', v_result);
  ASSERT (SELECT skipped_reason FROM app_internal.engagement_pushes WHERE dedupe_key = 'st:banned') = 'banned';
  ASSERT (SELECT skipped_reason FROM app_internal.engagement_pushes WHERE dedupe_key = 'st:inactive') = 'inactive';
  ASSERT (SELECT skipped_reason FROM app_internal.engagement_pushes WHERE dedupe_key = 'st:admin') = 'is_admin';
  ASSERT (SELECT count(*) FROM public.notifications WHERE user_id IN (v_banned, v_inactive, v_admin)) = 0;
  RAISE NOTICE 'ok: banned / inactive / is_admin skips';
END $$;

DO $$
DECLARE
  v_admin UUID := test.make_user('admin-only@test.local', 'business', true);
  v_user UUID := test.make_user('regular-only@test.local');
  v_base TIMESTAMPTZ := '2026-03-10 12:00:00+03';
  v_result RECORD;
BEGIN
  UPDATE public.feature_flags SET value = '"admins_only"' WHERE key = 'engagement_push_mode';
  PERFORM app_internal.enqueue_engagement_push(v_admin, 'weekly_digest', 't', 'b', '{}', 'ao:admin', v_base - INTERVAL '1 hour');
  PERFORM app_internal.enqueue_engagement_push(v_user,  'weekly_digest', 't', 'b', '{}', 'ao:user',  v_base - INTERVAL '1 hour');

  SELECT * INTO v_result FROM app_internal.process_engagement_pushes(v_base);
  ASSERT (v_result.sent, v_result.skipped, v_result.deferred) = (1, 1, 0), format('expected (1,1,0), got %s', v_result);
  ASSERT (SELECT sent_at FROM app_internal.engagement_pushes WHERE dedupe_key = 'ao:admin') = v_base;
  ASSERT (SELECT skipped_reason FROM app_internal.engagement_pushes WHERE dedupe_key = 'ao:user') = 'admins_only';
  ASSERT (SELECT count(*) FROM app_internal.apns_dispatch_log WHERE recipient_id = v_admin AND kind = 'weekly_digest') = 1;
  ASSERT (SELECT count(*) FROM public.notifications WHERE user_id = v_user) = 0;
  RAISE NOTICE 'ok: admins_only sends to admins only';
END $$;

DO $$
DECLARE
  v_user UUID := test.make_user('dry-run@test.local');
  v_base TIMESTAMPTZ := '2026-03-10 12:00:00+03';
  v_result RECORD;
BEGIN
  UPDATE public.feature_flags SET value = '"dry_run"' WHERE key = 'engagement_push_mode';
  PERFORM app_internal.enqueue_engagement_push(v_user, 'weekly_digest', 't', 'b', '{}', 'dr:1', v_base - INTERVAL '1 hour');

  SELECT * INTO v_result FROM app_internal.process_engagement_pushes(v_base);
  ASSERT (v_result.sent, v_result.skipped, v_result.deferred) = (0, 1, 0), format('expected (0,1,0), got %s', v_result);
  ASSERT (SELECT skipped_reason FROM app_internal.engagement_pushes WHERE dedupe_key = 'dr:1') = 'dry_run';
  ASSERT (SELECT count(*) FROM public.notifications WHERE user_id = v_user) = 0, 'dry_run must not insert notifications';
  RAISE NOTICE 'ok: dry_run marks rows without sending';
END $$;

DO $$
DECLARE
  v_user UUID := test.make_user('switched-off@test.local');
  v_base TIMESTAMPTZ := '2026-03-10 12:00:00+03';
  v_result RECORD;
BEGIN
  UPDATE public.feature_flags SET value = '"on"' WHERE key = 'engagement_push_mode';
  PERFORM app_internal.enqueue_engagement_push(v_user, 'app_update', 't', 'b', '{}', 'sw:1', v_base - INTERVAL '1 hour');

  UPDATE public.feature_flags SET value = '"off"' WHERE key = 'engagement_push_mode';
  SELECT * INTO v_result FROM app_internal.process_engagement_pushes(v_base);
  ASSERT (v_result.sent, v_result.skipped, v_result.deferred) = (0, 0, 0), format('expected (0,0,0), got %s', v_result);
  ASSERT (SELECT sent_at IS NULL AND skipped_reason IS NULL AND send_after = v_base - INTERVAL '1 hour'
          FROM app_internal.engagement_pushes WHERE dedupe_key = 'sw:1'),
    'mode off must leave the row untouched';

  UPDATE public.feature_flags SET value = '"on"' WHERE key = 'engagement_push_mode';
  SELECT * INTO v_result FROM app_internal.process_engagement_pushes(v_base);
  ASSERT (v_result.sent, v_result.skipped, v_result.deferred) = (1, 0, 0), format('after re-enable: expected (1,0,0), got %s', v_result);
  RAISE NOTICE 'ok: mode off leaves rows queued, re-enable sends them';
END $$;

-- ---------------------------------------------------------------------------
-- batch_size
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_user UUID := test.make_user('batch@test.local');
  v_base TIMESTAMPTZ := '2026-03-10 12:00:00+03';
  v_result RECORD;
BEGIN
  UPDATE public.feature_flags SET value = '"on"' WHERE key = 'engagement_push_mode';
  UPDATE public.feature_flags SET value = '{"batch_size": 2}' WHERE key = 'engagement_push_config';
  PERFORM app_internal.enqueue_engagement_push(v_user, 'app_update', 't', 'b', '{}', 'bt:' || i, v_base - INTERVAL '1 hour')
  FROM generate_series(1, 3) i;

  SELECT * INTO v_result FROM app_internal.process_engagement_pushes(v_base);
  ASSERT (v_result.sent, v_result.skipped, v_result.deferred) = (2, 0, 0), format('expected (2,0,0), got %s', v_result);
  SELECT * INTO v_result FROM app_internal.process_engagement_pushes(v_base);
  ASSERT (v_result.sent, v_result.skipped, v_result.deferred) = (1, 0, 0), format('second tick: expected (1,0,0), got %s', v_result);
  UPDATE public.feature_flags SET value = '{}' WHERE key = 'engagement_push_config';
  RAISE NOTICE 'ok: batch_size limits one tick';
END $$;

-- ---------------------------------------------------------------------------
-- per-row error isolation
-- ---------------------------------------------------------------------------
-- A trigger that fails the notifications INSERT for one chosen user stands in
-- for any unexpected per-row failure.
CREATE FUNCTION test.fail_notification_for_user()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.user_id::TEXT = current_setting('test.fail_user', true) THEN
    RAISE EXCEPTION 'simulated failure for %', NEW.user_id;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER test_fail_notification BEFORE INSERT ON public.notifications
  FOR EACH ROW EXECUTE FUNCTION test.fail_notification_for_user();

DO $$
DECLARE
  v_ok1 UUID := test.make_user('err-ok1@test.local');
  v_bad UUID := test.make_user('err-bad@test.local');
  v_ok2 UUID := test.make_user('err-ok2@test.local');
  v_base TIMESTAMPTZ := '2026-03-10 12:00:00+03';
  v_result RECORD;
BEGIN
  UPDATE public.feature_flags SET value = '"on"' WHERE key = 'engagement_push_mode';
  PERFORM set_config('test.fail_user', v_bad::TEXT, true);
  PERFORM app_internal.enqueue_engagement_push(v_ok1, 'app_update', 't', 'b', '{}', 'err:1', v_base - INTERVAL '3 hours');
  PERFORM app_internal.enqueue_engagement_push(v_bad, 'app_update', 't', 'b', '{}', 'err:2', v_base - INTERVAL '2 hours');
  PERFORM app_internal.enqueue_engagement_push(v_ok2, 'app_update', 't', 'b', '{}', 'err:3', v_base - INTERVAL '1 hour');

  SELECT * INTO v_result FROM app_internal.process_engagement_pushes(v_base);
  ASSERT (v_result.sent, v_result.skipped, v_result.deferred) = (2, 1, 0), format('expected (2,1,0), got %s', v_result);
  ASSERT (SELECT skipped_reason FROM app_internal.engagement_pushes WHERE dedupe_key = 'err:2') = 'error';
  ASSERT (SELECT sent_at IS NULL FROM app_internal.engagement_pushes WHERE dedupe_key = 'err:2');
  ASSERT (SELECT array_agg(dedupe_key ORDER BY dedupe_key) FROM app_internal.engagement_pushes
          WHERE dedupe_key IN ('err:1', 'err:3') AND sent_at = v_base) = ARRAY['err:1', 'err:3'],
    'rows after the failing one must still be sent';
  ASSERT (SELECT count(*) FROM public.notifications WHERE user_id = v_bad) = 0;
  ASSERT (SELECT count(*) FROM public.notifications WHERE user_id IN (v_ok1, v_ok2)) = 2;
  PERFORM set_config('test.fail_user', '', true);
  RAISE NOTICE 'ok: a throwing row is journaled as error, the rest of the batch is sent';
END $$;

DROP TRIGGER test_fail_notification ON public.notifications;
DROP FUNCTION test.fail_notification_for_user();

-- ---------------------------------------------------------------------------
-- malformed config
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_user UUID := test.make_user('badcfg@test.local');
  v_base TIMESTAMPTZ := '2026-03-10 12:00:00+03';
  v_result RECORD;
BEGIN
  UPDATE public.feature_flags SET value = '{"batch_size":"abc","quiet_start_hour":null,"marketing_daily_limit":1.5,"quiet_end_hour":{"x":1}}'
   WHERE key = 'engagement_push_config';
  ASSERT app_internal.engagement_cfg_int(app_internal.engagement_push_config(), 'batch_size', 200) = 200;
  ASSERT app_internal.engagement_cfg_int(app_internal.engagement_push_config(), 'quiet_start_hour', 21) = 21;
  ASSERT app_internal.engagement_cfg_int(app_internal.engagement_push_config(), 'marketing_daily_limit', 1) = 1;
  ASSERT app_internal.engagement_cfg_int(app_internal.engagement_push_config(), 'quiet_end_hour', 10) = 10;
  ASSERT app_internal.engagement_cfg_int(app_internal.engagement_push_config(), 'marketing_weekly_limit', 3) = 3, 'untouched key keeps its default';

  -- Kill switch must work regardless of the config contents.
  UPDATE public.feature_flags SET value = '"off"' WHERE key = 'engagement_push_mode';
  PERFORM app_internal.enqueue_engagement_push(v_user, 'app_update', 't', 'b', '{}', 'cfg:off', v_base - INTERVAL '1 hour');
  SELECT * INTO v_result FROM app_internal.process_engagement_pushes(v_base);
  ASSERT (v_result.sent, v_result.skipped, v_result.deferred) = (0, 0, 0), format('off: expected (0,0,0), got %s', v_result);

  UPDATE public.feature_flags SET value = '"on"' WHERE key = 'engagement_push_mode';
  PERFORM app_internal.enqueue_engagement_push(v_user, 'app_update', 't', 'b', '{}', 'cfg:1', v_base - INTERVAL '1 hour');
  PERFORM app_internal.enqueue_engagement_push(v_user, 'weekly_digest', 't', 'b', '{}', 'cfg:2', v_base - INTERVAL '1 hour');
  PERFORM app_internal.enqueue_engagement_push(v_user, 'weekly_digest', 't', 'b', '{}', 'cfg:3', v_base - INTERVAL '30 minutes');
  SELECT * INTO v_result FROM app_internal.process_engagement_pushes(v_base);
  ASSERT (v_result.sent, v_result.skipped, v_result.deferred) = (2, 1, 0), format('defaults: expected (2,1,0), got %s', v_result);
  ASSERT (SELECT skipped_reason FROM app_internal.engagement_pushes WHERE dedupe_key = 'cfg:3') = 'daily_limit',
    'default marketing_daily_limit = 1 must apply';
  -- Quiet hours default (21..10) still applies with the broken flag.
  PERFORM app_internal.enqueue_engagement_push(v_user, 'app_update', 't', 'b', '{}', 'cfg:night', v_base + INTERVAL '11 hours');
  SELECT * INTO v_result FROM app_internal.process_engagement_pushes(v_base + INTERVAL '11 hours');
  ASSERT (v_result.sent, v_result.skipped, v_result.deferred) = (0, 0, 1), format('23:00: expected (0,0,1), got %s', v_result);
  ASSERT (SELECT send_after FROM app_internal.engagement_pushes WHERE dedupe_key = 'cfg:night') = '2026-03-11 10:00:00+03'::timestamptz;
  UPDATE public.feature_flags SET value = '{}' WHERE key = 'engagement_push_config';
  RAISE NOTICE 'ok: malformed config falls back to defaults, kill switch unaffected';
END $$;

-- ---------------------------------------------------------------------------
-- daytime (non-wrapping) quiet window
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_user UUID := test.make_user('daywindow@test.local');
  v_result RECORD;
BEGIN
  UPDATE public.feature_flags SET value = '"on"' WHERE key = 'engagement_push_mode';
  UPDATE public.feature_flags SET value = '{"quiet_start_hour":1,"quiet_end_hour":5}' WHERE key = 'engagement_push_config';

  PERFORM app_internal.enqueue_engagement_push(v_user, 'app_update', 't', 'b', '{}', 'dw:1', '2026-03-10 02:00:00+03');
  SELECT * INTO v_result FROM app_internal.process_engagement_pushes('2026-03-10 03:00:00+03');
  ASSERT (v_result.sent, v_result.skipped, v_result.deferred) = (0, 0, 1), format('03:00: expected (0,0,1), got %s', v_result);
  ASSERT (SELECT send_after FROM app_internal.engagement_pushes WHERE dedupe_key = 'dw:1') = '2026-03-10 05:00:00+03'::timestamptz,
    '03:00 MSK must defer to 05:00 MSK the same day';

  SELECT * INTO v_result FROM app_internal.process_engagement_pushes('2026-03-10 12:00:00+03');
  ASSERT (v_result.sent, v_result.skipped, v_result.deferred) = (1, 0, 0), format('12:00: expected (1,0,0), got %s', v_result);

  -- 23:00 is outside a 1..5 window.
  PERFORM app_internal.enqueue_engagement_push(v_user, 'app_update', 't', 'b', '{}', 'dw:2', '2026-03-10 22:00:00+03');
  SELECT * INTO v_result FROM app_internal.process_engagement_pushes('2026-03-10 23:00:00+03');
  ASSERT (v_result.sent, v_result.skipped, v_result.deferred) = (1, 0, 0), format('23:00: expected (1,0,0), got %s', v_result);
  UPDATE public.feature_flags SET value = '{}' WHERE key = 'engagement_push_config';
  RAISE NOTICE 'ok: daytime quiet window 1..5';
END $$;

-- ---------------------------------------------------------------------------
-- admin RPCs
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_admin UUID := test.make_user('rpc-admin@test.local', 'business', true);
  v_user UUID := test.make_user('rpc-user@test.local');
  v_other UUID := test.make_user('rpc-other@test.local', 'business');
  v_denied BOOLEAN := false;
  v_total BIGINT;
  v_rows BIGINT;
  v_first RECORD;
  v_counts RECORD;
BEGIN
  -- Journal state written directly (now()-relative so the 7-day counts apply).
  DELETE FROM app_internal.engagement_pushes;
  INSERT INTO app_internal.engagement_pushes (user_id, kind, title, body, data, dedupe_key, send_after, sent_at, skipped_reason, created_at)
  VALUES
    (v_user,  'weekly_digest',  't1', 'b1', '{"a": "1"}', 'rpc:1', now() - INTERVAL '2 days', now() - INTERVAL '2 days', NULL, now() - INTERVAL '3 days'),
    (v_user,  'weekly_digest',  't2', 'b2', '{}',         'rpc:2', now() - INTERVAL '1 day',  NULL, 'daily_limit',       now() - INTERVAL '2 days'),
    (v_other, 'weekly_digest',  't3', 'b3', '{}',         'rpc:3', now() + INTERVAL '1 hour', NULL, NULL,                now() - INTERVAL '1 day'),
    (v_other, 'new_job_nearby', 't4', 'b4', '{}',         'rpc:4', now() - INTERVAL '10 days', now() - INTERVAL '10 days', NULL, now() - INTERVAL '10 days'),
    (v_other, 'new_job_nearby', 't5', 'b5', '{}',         'rpc:5', now() - INTERVAL '1 hour', NULL, 'pref_disabled',     now());

  PERFORM test.act_as(v_user);
  BEGIN
    PERFORM * FROM public.admin_engagement_pushes();
  EXCEPTION WHEN insufficient_privilege THEN
    v_denied := true;
  END;
  ASSERT v_denied, 'non-admin must get 42501 from admin_engagement_pushes';
  v_denied := false;
  BEGIN
    PERFORM * FROM public.admin_engagement_push_counts();
  EXCEPTION WHEN insufficient_privilege THEN
    v_denied := true;
  END;
  ASSERT v_denied, 'non-admin must get 42501 from admin_engagement_push_counts';

  PERFORM test.act_as(v_admin);

  SELECT count(*), min(total_count) INTO v_rows, v_total FROM public.admin_engagement_pushes();
  ASSERT (v_rows, v_total) = (5, 5), format('all: expected (5,5), got (%s,%s)', v_rows, v_total);

  SELECT * INTO v_first FROM public.admin_engagement_pushes() LIMIT 1;
  ASSERT v_first.dedupe_key = 'rpc:5', 'newest created_at first, got ' || v_first.dedupe_key;
  ASSERT (v_first.user_email, v_first.account_type) = ('rpc-other@test.local', 'business');

  SELECT count(*), min(total_count) INTO v_rows, v_total FROM public.admin_engagement_pushes(p_kind := 'weekly_digest');
  ASSERT (v_rows, v_total) = (3, 3), format('kind filter: expected (3,3), got (%s,%s)', v_rows, v_total);

  SELECT count(*), min(total_count) INTO v_rows, v_total FROM public.admin_engagement_pushes(p_status := 'queued');
  ASSERT (v_rows, v_total) = (1, 1), format('queued: expected (1,1), got (%s,%s)', v_rows, v_total);
  ASSERT (SELECT dedupe_key FROM public.admin_engagement_pushes(p_status := 'queued')) = 'rpc:3';

  SELECT count(*), min(total_count) INTO v_rows, v_total FROM public.admin_engagement_pushes(p_status := 'sent');
  ASSERT (v_rows, v_total) = (2, 2), format('sent: expected (2,2), got (%s,%s)', v_rows, v_total);

  SELECT count(*), min(total_count) INTO v_rows, v_total FROM public.admin_engagement_pushes(p_status := 'skipped', p_skipped_reason := 'daily_limit');
  ASSERT (v_rows, v_total) = (1, 1), format('skipped+reason: expected (1,1), got (%s,%s)', v_rows, v_total);

  SELECT count(*), min(total_count) INTO v_rows, v_total FROM public.admin_engagement_pushes(p_limit := 2, p_offset := 0);
  ASSERT (v_rows, v_total) = (2, 5), format('page 1: expected (2,5), got (%s,%s)', v_rows, v_total);
  SELECT count(*), min(total_count) INTO v_rows, v_total FROM public.admin_engagement_pushes(p_limit := 2, p_offset := 4);
  ASSERT (v_rows, v_total) = (1, 5), format('last page: expected (1,5), got (%s,%s)', v_rows, v_total);
  SELECT count(*) INTO v_rows FROM public.admin_engagement_pushes(p_limit := 0);
  ASSERT v_rows = 1, 'p_limit must clamp to at least 1';

  v_denied := false;
  BEGIN
    PERFORM * FROM public.admin_engagement_pushes(p_status := 'bogus');
  EXCEPTION WHEN invalid_parameter_value THEN
    v_denied := true;
  END;
  ASSERT v_denied, 'unknown status must raise 22023';

  ASSERT (SELECT count(*) FROM public.admin_engagement_push_counts()) = 2, 'one counts row per kind';
  SELECT * INTO v_counts FROM public.admin_engagement_push_counts() WHERE kind = 'weekly_digest';
  ASSERT (v_counts.queued, v_counts.sent_7d, v_counts.skipped_7d) = (1, 1, 1), format('weekly_digest counts: %s', v_counts);
  SELECT * INTO v_counts FROM public.admin_engagement_push_counts() WHERE kind = 'new_job_nearby';
  ASSERT (v_counts.queued, v_counts.sent_7d, v_counts.skipped_7d) = (0, 0, 1), format('new_job_nearby counts: %s', v_counts);

  PERFORM test.act_as(NULL);
  RAISE NOTICE 'ok: admin RPCs (42501 for non-admins, filters, total_count, counts)';
END $$;

-- ---------------------------------------------------------------------------
-- grants
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  ASSERT NOT has_function_privilege('anon', 'public.admin_engagement_pushes(text,text,text,int,int)', 'EXECUTE');
  ASSERT NOT has_function_privilege('anon', 'public.admin_engagement_push_counts()', 'EXECUTE');
  ASSERT has_function_privilege('authenticated', 'public.admin_engagement_pushes(text,text,text,int,int)', 'EXECUTE');
  ASSERT NOT has_function_privilege('authenticated', 'app_internal.process_engagement_pushes(timestamptz)', 'EXECUTE');
  ASSERT NOT has_function_privilege('authenticated', 'app_internal.enqueue_engagement_push(uuid,text,text,text,jsonb,text,timestamptz)', 'EXECUTE');
  ASSERT NOT has_function_privilege('authenticated', 'public.notify_admin_initiated_notification()', 'EXECUTE');
  ASSERT NOT has_table_privilege('authenticated', 'app_internal.engagement_pushes', 'SELECT');
  ASSERT (SELECT count(*) FROM cron.job WHERE jobname = 'process_engagement_pushes' AND schedule = '*/5 * * * *') = 1;
  RAISE NOTICE 'ok: grants and cron job';
END $$;

ROLLBACK;

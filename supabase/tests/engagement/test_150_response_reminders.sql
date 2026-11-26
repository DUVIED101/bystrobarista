-- Tests for 150_response_reminders.sql. Run through run.sh (fixtures +
-- migrations are applied first). One transaction, rolled back at the end.
--
-- Launch marker pinned to M = 2026-11-20 09:00 MSK; every tick is driven
-- through p_now. Each section deletes its jobs at the end (applications and
-- offers cascade) so the return counts of later ticks are not polluted.
BEGIN;

-- compute_shift_start (129) is not part of the fixtures; the cron reads it
-- through shift_start_or_null at run time.
DO $$
BEGIN
  IF to_regprocedure('app_internal.compute_shift_start(jsonb)') IS NULL THEN
    EXECUTE $def$
      CREATE FUNCTION app_internal.compute_shift_start(p_shift JSONB)
      RETURNS TIMESTAMPTZ
      LANGUAGE plpgsql IMMUTABLE
      AS $f$
      DECLARE
        v_date DATE := ((p_shift->>'startDate')::timestamptz AT TIME ZONE 'Europe/Moscow')::date;
        v_time TIME := (p_shift->>'startTime')::TIME;
      BEGIN
        RETURN (v_date + v_time) AT TIME ZONE 'Europe/Moscow';
      END;
      $f$
    $def$;
  END IF;
END $$;

UPDATE public.feature_flags SET value = '"on"' WHERE key = 'engagement_push_mode';
UPDATE public.feature_flags SET value = to_jsonb('2026-11-20 09:00:00+03'::text) WHERE key = 'reminders_started_at';

CREATE FUNCTION pg_temp.marker() RETURNS TIMESTAMPTZ LANGUAGE sql IMMUTABLE
AS $$ SELECT '2026-11-20 09:00+03'::timestamptz $$;

CREATE FUNCTION pg_temp.tick(p_now TIMESTAMPTZ) RETURNS INT[] LANGUAGE sql VOLATILE
AS $$
  SELECT ARRAY[r.application_reminders, r.application_expired, r.offer_reminders, r.offer_expired]
  FROM app_internal.process_response_reminders(p_now) r
$$;

CREATE FUNCTION pg_temp.make_job(
  p_owner UUID, p_title TEXT, p_status TEXT DEFAULT 'open',
  p_shift JSONB DEFAULT '{"startDate": "2026-12-30", "startTime": "09:00"}'::jsonb,
  p_city TEXT DEFAULT 'spb'
) RETURNS UUID LANGUAGE plpgsql VOLATILE
AS $$
DECLARE
  v_business UUID;
  v_branch UUID;
  v_job UUID;
BEGIN
  SELECT id INTO v_business FROM public.businesses WHERE owner_id = p_owner;
  INSERT INTO public.branches (business_id, city) VALUES (v_business, p_city) RETURNING id INTO v_branch;
  INSERT INTO public.jobs (business_id, business_owner_id, branch_id, title, status, shift_details)
  VALUES (v_business, p_owner, v_branch, p_title, p_status, p_shift)
  RETURNING id INTO v_job;
  RETURN v_job;
END $$;

CREATE FUNCTION pg_temp.make_app(p_job UUID, p_barista UUID, p_created TIMESTAMPTZ, p_via_offer BOOLEAN DEFAULT false)
RETURNS UUID LANGUAGE sql VOLATILE
AS $$
  INSERT INTO public.applications (job_id, barista_id, status, created_via_offer, created_at, updated_at)
  VALUES (p_job, p_barista, 'pending', p_via_offer, p_created, p_created)
  RETURNING id
$$;

CREATE FUNCTION pg_temp.make_offer(p_owner UUID, p_barista UUID, p_job UUID, p_created TIMESTAMPTZ)
RETURNS UUID LANGUAGE sql VOLATILE
AS $$
  INSERT INTO public.job_offers (business_owner_id, barista_id, job_id, status, created_at)
  VALUES (p_owner, p_barista, p_job, 'pending', p_created)
  RETURNING id
$$;

-- {status, r24, r72, expired_at, responded_at} of an application / offer.
CREATE FUNCTION pg_temp.app_state(p_id UUID) RETURNS JSONB LANGUAGE sql STABLE
AS $$
  SELECT jsonb_build_object('status', a.status, 'r24', a.reminder_24h_sent_at, 'r72', a.reminder_72h_sent_at,
                            'expired_at', a.expired_at, 'responded_at', a.responded_at)
  FROM public.applications a WHERE a.id = p_id
$$;

CREATE FUNCTION pg_temp.offer_state(p_id UUID) RETURNS JSONB LANGUAGE sql STABLE
AS $$
  SELECT jsonb_build_object('status', o.status, 'r24', o.reminder_24h_sent_at, 'r72', o.reminder_72h_sent_at,
                            'expired_at', o.expired_at, 'responded_at', o.responded_at)
  FROM public.job_offers o WHERE o.id = p_id
$$;

CREATE FUNCTION pg_temp.state(p_status TEXT, p_r24 TIMESTAMPTZ, p_r72 TIMESTAMPTZ, p_expired TIMESTAMPTZ, p_responded TIMESTAMPTZ)
RETURNS JSONB LANGUAGE sql IMMUTABLE
AS $$
  SELECT jsonb_build_object('status', p_status, 'r24', p_r24, 'r72', p_r72, 'expired_at', p_expired, 'responded_at', p_responded)
$$;

-- Queue rows for one recipient and kind as [{title, body, data, dedupe_key, send_after}] in insertion order.
CREATE FUNCTION pg_temp.pushes(p_user UUID, p_kind TEXT) RETURNS JSONB LANGUAGE sql STABLE
AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'title', ep.title, 'body', ep.body, 'data', ep.data,
           'dedupe_key', ep.dedupe_key, 'send_after', ep.send_after) ORDER BY ep.id), '[]'::jsonb)
  FROM app_internal.engagement_pushes ep
  WHERE ep.user_id = p_user AND ep.kind = p_kind
$$;

CREATE FUNCTION pg_temp.push(p_title TEXT, p_body TEXT, p_data JSONB, p_dedupe TEXT, p_send_after TIMESTAMPTZ)
RETURNS JSONB LANGUAGE sql IMMUTABLE
AS $$
  SELECT jsonb_build_object('title', p_title, 'body', p_body, 'data', p_data, 'dedupe_key', p_dedupe, 'send_after', p_send_after)
$$;

CREATE FUNCTION pg_temp.push_count(p_user UUID) RETURNS BIGINT LANGUAGE sql STABLE
AS $$ SELECT count(*) FROM app_internal.engagement_pushes ep WHERE ep.user_id = p_user $$;

-- ---------------------------------------------------------------------------
-- 0. Launch marker reader
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  ASSERT app_internal.reminders_started_at() = pg_temp.marker(), 'reminders_started_at reads the flag';

  UPDATE public.feature_flags SET value = '"not a date"' WHERE key = 'reminders_started_at';
  ASSERT app_internal.reminders_started_at() = now(), 'reminders_started_at: unparsable flag reads as now()';

  UPDATE public.feature_flags SET value = '{"at": 1}' WHERE key = 'reminders_started_at';
  ASSERT app_internal.reminders_started_at() = now(), 'reminders_started_at: non-string flag reads as now()';

  DELETE FROM public.feature_flags WHERE key = 'reminders_started_at';
  ASSERT app_internal.reminders_started_at() = now(), 'reminders_started_at: missing flag reads as now()';

  INSERT INTO public.feature_flags (key, value) VALUES ('reminders_started_at', to_jsonb(pg_temp.marker()::text));

  ASSERT (
    SELECT ARRAY[
      app_internal.shift_start_or_null('{"startDate": "2026-11-22", "startTime": "08:00"}'),
      app_internal.shift_start_or_null('{"startDate": "2026-11-21T21:00:00.000Z", "startTime": "08:00"}'),
      app_internal.shift_start_or_null('{"startDate": "garbage", "startTime": "08:00"}'),
      app_internal.shift_start_or_null('{"startDate": "2026-11-22"}'),
      app_internal.shift_start_or_null(NULL)
    ]
  ) = ARRAY['2026-11-22 08:00+03'::timestamptz, '2026-11-22 08:00+03', NULL, NULL, NULL],
    'shift_start_or_null: Moscow shift start for bare and ISO dates, NULL for garbage or missing parts';

  RAISE NOTICE 'ok: reminders_started_at / shift_start_or_null';
END $$;

-- ---------------------------------------------------------------------------
-- 1. Legacy application: one reminder, never auto-closed
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_biz UUID := test.make_user('t1-biz@test.local', 'business');
  v_bar UUID := test.make_user('t1-bar@test.local', 'barista');
  v_bar_dead UUID := test.make_user('t1-bar-dead@test.local', 'barista');
  v_job UUID := pg_temp.make_job(v_biz, 'Утренняя смена');
  v_job_filled UUID := pg_temp.make_job(v_biz, 'Занятая смена', 'filled');
  v_app UUID := pg_temp.make_app(v_job, v_bar, pg_temp.marker() - INTERVAL '30 days');
  v_app_dead UUID := pg_temp.make_app(v_job_filled, v_bar_dead, pg_temp.marker() - INTERVAL '30 days');
  v_t1 TIMESTAMPTZ := pg_temp.marker() + INTERVAL '1 hour';
BEGIN
  ASSERT pg_temp.tick(v_t1) = ARRAY[1, 0, 0, 0], 'legacy application: first tick returns one reminder';
  ASSERT pg_temp.app_state(v_app_dead) = pg_temp.state('pending', NULL, NULL, NULL, NULL),
    'legacy application on a filled job: no reminder, no stamp, still pending';
  ASSERT pg_temp.pushes(v_biz, 'application_reminder') = jsonb_build_array(pg_temp.push(
      'Бариста ждёт ответа',
      'Бариста ждёт ответа на отклик: Утренняя смена',
      jsonb_build_object('kind', 'application_reminder', 'jobId', v_job::text, 'count', '1'),
      'ar:' || v_biz::text || ':2026-11-20',
      v_t1)),
    format('legacy application: one reminder push, got %s', pg_temp.pushes(v_biz, 'application_reminder'));
  ASSERT pg_temp.app_state(v_app) = pg_temp.state('pending', v_t1, NULL, NULL, NULL),
    'legacy application: reminder_24h_sent_at stamped, still pending';

  ASSERT pg_temp.tick(v_t1 + INTERVAL '1 hour') = ARRAY[0, 0, 0, 0], 'legacy application: second tick does nothing';
  ASSERT pg_temp.tick(v_t1 + INTERVAL '8 days') = ARRAY[0, 0, 0, 0], 'legacy application: +8 days does nothing';
  ASSERT pg_temp.app_state(v_app) = pg_temp.state('pending', v_t1, NULL, NULL, NULL),
    'legacy application: never auto-closed';
  ASSERT pg_temp.push_count(v_biz) = 1 AND pg_temp.push_count(v_bar) = 0 AND pg_temp.push_count(v_bar_dead) = 0,
    'legacy application: exactly one push overall';

  DELETE FROM public.jobs WHERE id IN (v_job, v_job_filled);
  RAISE NOTICE 'ok: legacy application';
END $$;

-- ---------------------------------------------------------------------------
-- 2. New application timeline: 24h, 72h, 7 days
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_biz UUID := test.make_user('t2-biz@test.local', 'business');
  v_bar UUID := test.make_user('t2-bar@test.local', 'barista');
  v_job UUID := pg_temp.make_job(v_biz, 'Вечерняя смена');
  v_c TIMESTAMPTZ := '2026-11-21 10:00+03';
  v_app UUID := pg_temp.make_app(v_job, v_bar, v_c);
  v_t24 TIMESTAMPTZ := v_c + INTERVAL '24 hours';
  v_t72 TIMESTAMPTZ := v_c + INTERVAL '72 hours';
  v_t7d TIMESTAMPTZ := v_c + INTERVAL '7 days';
BEGIN
  ASSERT pg_temp.tick(v_c + INTERVAL '23 hours') = ARRAY[0, 0, 0, 0], 'new application: nothing at 23h';
  ASSERT pg_temp.app_state(v_app) = pg_temp.state('pending', NULL, NULL, NULL, NULL), 'new application: unstamped at 23h';

  ASSERT pg_temp.tick(v_t24) = ARRAY[1, 0, 0, 0], 'new application: 24h reminder';
  ASSERT pg_temp.pushes(v_biz, 'application_reminder') = jsonb_build_array(pg_temp.push(
      'Бариста ждёт ответа',
      'Бариста ждёт ответа на отклик: Вечерняя смена',
      jsonb_build_object('kind', 'application_reminder', 'jobId', v_job::text, 'count', '1'),
      'ar:' || v_biz::text || ':2026-11-22',
      v_t24)),
    format('new application: 24h push, got %s', pg_temp.pushes(v_biz, 'application_reminder'));
  ASSERT pg_temp.app_state(v_app) = pg_temp.state('pending', v_t24, NULL, NULL, NULL), 'new application: 24h stamped';

  ASSERT pg_temp.tick(v_c + INTERVAL '25 hours') = ARRAY[0, 0, 0, 0], 'new application: nothing at 25h';

  ASSERT pg_temp.tick(v_t72) = ARRAY[1, 0, 0, 0], 'new application: 72h reminder';
  ASSERT (SELECT jsonb_agg(p->>'dedupe_key') FROM jsonb_array_elements(pg_temp.pushes(v_biz, 'application_reminder')) p)
    = jsonb_build_array('ar:' || v_biz::text || ':2026-11-22', 'ar:' || v_biz::text || ':2026-11-24'),
    'new application: the 72h reminder has a different MSK date in its dedupe key';
  ASSERT pg_temp.app_state(v_app) = pg_temp.state('pending', v_t24, v_t72, NULL, NULL), 'new application: 72h stamped, 24h kept';

  ASSERT pg_temp.tick(v_t7d) = ARRAY[0, 1, 0, 0], 'new application: expired at 7 days';
  ASSERT pg_temp.app_state(v_app) = pg_temp.state('expired', v_t24, v_t72, v_t7d, NULL),
    'new application: status expired, expired_at = p_now, responded_at NULL';
  ASSERT pg_temp.pushes(v_bar, 'application_expired') = jsonb_build_array(pg_temp.push(
      'Кофейня не ответила',
      'Отклик на «Вечерняя смена» закрыт без ответа. Посмотрите похожие смены',
      jsonb_build_object('kind', 'application_expired', 'applicationId', v_app::text, 'jobId', v_job::text, 'city', 'spb'),
      'ae:' || v_app::text,
      v_t7d)),
    format('new application: application_expired push to the barista, got %s', pg_temp.pushes(v_bar, 'application_expired'));

  ASSERT pg_temp.tick(v_t7d + INTERVAL '1 hour') = ARRAY[0, 0, 0, 0], 'new application: nothing after expiry';
  ASSERT pg_temp.push_count(v_biz) = 2 AND pg_temp.push_count(v_bar) = 1, 'new application: 2 reminders + 1 expiry overall';

  DELETE FROM public.jobs WHERE id = v_job;
  RAISE NOTICE 'ok: new application timeline';
END $$;

-- ---------------------------------------------------------------------------
-- 3. Merging per owner; created_via_offer rows ignored
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_biz UUID := test.make_user('t3-biz@test.local', 'business');
  v_bar_a UUID := test.make_user('t3-bar-a@test.local', 'barista');
  v_bar_b UUID := test.make_user('t3-bar-b@test.local', 'barista');
  v_bar_c UUID := test.make_user('t3-bar-c@test.local', 'barista');
  v_bar_d UUID := test.make_user('t3-bar-d@test.local', 'barista');
  v_job_a UUID := pg_temp.make_job(v_biz, 'Смена А');
  v_job_b UUID := pg_temp.make_job(v_biz, 'Смена Б');
  v_app_a UUID := pg_temp.make_app(v_job_a, v_bar_a, '2026-11-22 10:00+03');
  v_app_b UUID := pg_temp.make_app(v_job_a, v_bar_b, '2026-11-22 11:00+03');
  v_app_c UUID := pg_temp.make_app(v_job_b, v_bar_c, '2026-11-23 10:00+03');
  v_app_offer UUID := pg_temp.make_app(v_job_a, v_bar_d, '2026-11-22 09:00+03', true);
  v_t TIMESTAMPTZ := '2026-11-24 12:00+03';
BEGIN
  ASSERT pg_temp.tick(v_t) = ARRAY[1, 0, 0, 0], 'merging: one reminder message for three applications';
  ASSERT pg_temp.pushes(v_biz, 'application_reminder') = jsonb_build_array(pg_temp.push(
      'Бариста ждут ответа',
      '3 бариста ждут ответа на отклики',
      jsonb_build_object('kind', 'application_reminder', 'jobId', v_job_b::text, 'count', '3'),
      'ar:' || v_biz::text || ':2026-11-24',
      v_t)),
    format('merging: merged body with the most recent job id, got %s', pg_temp.pushes(v_biz, 'application_reminder'));
  ASSERT (SELECT array_agg(pg_temp.app_state(x) ORDER BY o) FROM unnest(ARRAY[v_app_a, v_app_b, v_app_c, v_app_offer]) WITH ORDINALITY AS u (x, o))
    = ARRAY[
        pg_temp.state('pending', v_t, NULL, NULL, NULL),
        pg_temp.state('pending', v_t, NULL, NULL, NULL),
        pg_temp.state('pending', v_t, NULL, NULL, NULL),
        pg_temp.state('pending', NULL, NULL, NULL, NULL)
      ],
    'merging: all three stamped, the created_via_offer row untouched';

  ASSERT pg_temp.tick(v_t + INTERVAL '1 hour') = ARRAY[0, 0, 0, 0], 'merging: nothing on the next tick';

  DELETE FROM public.jobs WHERE id IN (v_job_a, v_job_b);
  RAISE NOTICE 'ok: merging per owner';
END $$;

-- ---------------------------------------------------------------------------
-- 4. Early expiry: job not live, shift in the past; in_review stays live
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_biz UUID := test.make_user('t4-biz@test.local', 'business');
  v_bar_filled UUID := test.make_user('t4-bar-filled@test.local', 'barista');
  v_bar_past UUID := test.make_user('t4-bar-past@test.local', 'barista');
  v_bar_open UUID := test.make_user('t4-bar-open@test.local', 'barista');
  v_bar_review UUID := test.make_user('t4-bar-review@test.local', 'barista');
  v_job_filled UUID := pg_temp.make_job(v_biz, 'Занятая смена', 'filled');
  v_job_past UUID := pg_temp.make_job(v_biz, 'Прошедшая смена', 'open',
                       '{"startDate": "2026-11-22", "startTime": "08:00"}'::jsonb, 'moscow');
  v_job_open UUID := pg_temp.make_job(v_biz, 'Будущая смена', 'open',
                       '{"startDate": "2026-11-23T21:00:00.000Z", "startTime": "08:00"}'::jsonb);
  v_job_review UUID := pg_temp.make_job(v_biz, 'Смена на рассмотрении', 'in_review');
  v_created TIMESTAMPTZ := '2026-11-23 10:00+03';
  v_app_filled UUID := pg_temp.make_app(v_job_filled, v_bar_filled, v_created);
  v_app_past UUID := pg_temp.make_app(v_job_past, v_bar_past, v_created);
  v_app_open UUID := pg_temp.make_app(v_job_open, v_bar_open, v_created);
  v_app_review UUID := pg_temp.make_app(v_job_review, v_bar_review, v_created);
  v_t TIMESTAMPTZ := '2026-11-23 12:00+03';
BEGIN
  ASSERT pg_temp.tick(v_t) = ARRAY[0, 2, 0, 0], 'early expiry: two applications expired, no reminders yet';
  ASSERT (SELECT array_agg(pg_temp.app_state(x) ORDER BY o) FROM unnest(ARRAY[v_app_filled, v_app_past, v_app_open, v_app_review]) WITH ORDINALITY AS u (x, o))
    = ARRAY[
        pg_temp.state('expired', NULL, NULL, v_t, NULL),
        pg_temp.state('expired', NULL, NULL, v_t, NULL),
        pg_temp.state('pending', NULL, NULL, NULL, NULL),
        pg_temp.state('pending', NULL, NULL, NULL, NULL)
      ],
    'early expiry: filled job and past shift expired; open and in_review jobs keep their applications';
  ASSERT pg_temp.pushes(v_bar_filled, 'application_expired') = jsonb_build_array(pg_temp.push(
      'Отклик закрыт',
      'Смена «Занятая смена» больше не доступна, отклик закрыт. Посмотрите похожие смены',
      jsonb_build_object('kind', 'application_expired', 'applicationId', v_app_filled::text, 'jobId', v_job_filled::text, 'city', 'spb'),
      'ae:' || v_app_filled::text,
      v_t)),
    'early expiry: push for the filled job';
  ASSERT pg_temp.pushes(v_bar_past, 'application_expired') = jsonb_build_array(pg_temp.push(
      'Отклик закрыт',
      'Смена «Прошедшая смена» больше не доступна, отклик закрыт. Посмотрите похожие смены',
      jsonb_build_object('kind', 'application_expired', 'applicationId', v_app_past::text, 'jobId', v_job_past::text, 'city', 'moscow'),
      'ae:' || v_app_past::text,
      v_t)),
    'early expiry: push for the past shift carries the branch city';
  ASSERT pg_temp.push_count(v_bar_open) = 0 AND pg_temp.push_count(v_bar_review) = 0 AND pg_temp.push_count(v_biz) = 0,
    'early expiry: no other pushes';

  -- The future shift (24 Nov 08:00 MSK) starts: expired on the first tick after it.
  ASSERT pg_temp.tick('2026-11-24 08:00+03') = ARRAY[0, 0, 0, 0], 'early expiry: nothing at the shift start itself';
  ASSERT pg_temp.tick('2026-11-24 08:01+03') = ARRAY[0, 1, 0, 0], 'early expiry: expired once the shift has started';
  ASSERT pg_temp.app_state(v_app_open) = pg_temp.state('expired', NULL, NULL, '2026-11-24 08:01+03', NULL),
    'early expiry: ISO startDate read as a Moscow day';

  DELETE FROM public.jobs WHERE id IN (v_job_filled, v_job_past, v_job_open, v_job_review);
  RAISE NOTICE 'ok: early expiry';
END $$;

-- ---------------------------------------------------------------------------
-- 5. Admin rows ignored; banned recipient stamped and queued (the queue skips later)
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_adm_biz UUID := test.make_user('t5-adm-biz@test.local', 'business', true);
  v_adm_bar UUID := test.make_user('t5-adm-bar@test.local', 'barista', true);
  v_biz UUID := test.make_user('t5-biz@test.local', 'business');
  v_biz_banned UUID := test.make_user('t5-biz-banned@test.local', 'business');
  v_bar UUID := test.make_user('t5-bar@test.local', 'barista');
  v_bar2 UUID := test.make_user('t5-bar2@test.local', 'barista');
  v_job_adm UUID := pg_temp.make_job(v_adm_biz, 'Смена админа');
  v_job UUID := pg_temp.make_job(v_biz, 'Обычная смена');
  v_job_banned UUID := pg_temp.make_job(v_biz_banned, 'Смена заблокированного');
  v_created TIMESTAMPTZ := '2026-11-22 10:00+03';
  v_app_adm_owner UUID := pg_temp.make_app(v_job_adm, v_bar, v_created);
  v_app_adm_barista UUID := pg_temp.make_app(v_job, v_adm_bar, v_created);
  v_app_banned UUID := pg_temp.make_app(v_job_banned, v_bar2, v_created);
  v_t TIMESTAMPTZ := '2026-11-25 12:00+03';
  v_t8d TIMESTAMPTZ := '2026-11-30 12:00+03';
BEGIN
  UPDATE public.users SET banned_at = '2026-11-23 10:00+03' WHERE id = v_biz_banned;

  ASSERT pg_temp.tick(v_t) = ARRAY[1, 0, 0, 0], 'admin/banned: only the banned owner''s application is processed';
  ASSERT (SELECT array_agg(pg_temp.app_state(x) ORDER BY o) FROM unnest(ARRAY[v_app_adm_owner, v_app_adm_barista, v_app_banned]) WITH ORDINALITY AS u (x, o))
    = ARRAY[
        pg_temp.state('pending', NULL, NULL, NULL, NULL),
        pg_temp.state('pending', NULL, NULL, NULL, NULL),
        pg_temp.state('pending', v_t, v_t, NULL, NULL)
      ],
    'admin/banned: admin rows untouched, banned owner''s 74h-old row stamped 24h and 72h at once';
  ASSERT pg_temp.pushes(v_biz_banned, 'application_reminder') = jsonb_build_array(pg_temp.push(
      'Бариста ждёт ответа',
      'Бариста ждёт ответа на отклик: Смена заблокированного',
      jsonb_build_object('kind', 'application_reminder', 'jobId', v_job_banned::text, 'count', '1'),
      'ar:' || v_biz_banned::text || ':2026-11-25',
      v_t)),
    'admin/banned: the banned owner gets a queue row (process_engagement_pushes skips it later)';

  ASSERT pg_temp.tick(v_t8d) = ARRAY[0, 1, 0, 0], 'admin/banned: at 8 days only the banned owner''s application expires';
  ASSERT (SELECT array_agg(pg_temp.app_state(x) ORDER BY o) FROM unnest(ARRAY[v_app_adm_owner, v_app_adm_barista, v_app_banned]) WITH ORDINALITY AS u (x, o))
    = ARRAY[
        pg_temp.state('pending', NULL, NULL, NULL, NULL),
        pg_temp.state('pending', NULL, NULL, NULL, NULL),
        pg_temp.state('expired', v_t, v_t, v_t8d, NULL)
      ],
    'admin/banned: admin rows are never expired';
  ASSERT pg_temp.push_count(v_adm_biz) = 0 AND pg_temp.push_count(v_biz) = 0
     AND pg_temp.push_count(v_bar) = 0 AND pg_temp.push_count(v_adm_bar) = 0 AND pg_temp.push_count(v_bar2) = 1,
    'admin/banned: no pushes around admin rows, one expiry push to the banned owner''s applicant';

  DELETE FROM public.jobs WHERE id IN (v_job_adm, v_job, v_job_banned);
  RAISE NOTICE 'ok: admin and banned rows';
END $$;

-- ---------------------------------------------------------------------------
-- 6. Job offers
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_biz UUID := test.make_user('t6-biz@test.local', 'business');
  v_bar UUID := test.make_user('t6-bar@test.local', 'barista');
  v_job UUID := pg_temp.make_job(v_biz, 'Смена бариста');
  v_offer UUID := pg_temp.make_offer(v_biz, v_bar, v_job, pg_temp.marker() - INTERVAL '26 days');
  v_t1 TIMESTAMPTZ := pg_temp.marker() + INTERVAL '1 hour';
BEGIN
  UPDATE public.businesses SET name = 'Кофе Хауз' WHERE owner_id = v_biz;

  ASSERT pg_temp.tick(v_t1) = ARRAY[0, 0, 1, 0], 'legacy offer: one reminder on the first tick';
  ASSERT pg_temp.pushes(v_bar, 'job_offer_reminder') = jsonb_build_array(pg_temp.push(
      'Вам предложили смену',
      'Кофе Хауз ждёт ответа: Смена бариста',
      jsonb_build_object('kind', 'job_offer_reminder', 'offerId', v_offer::text, 'count', '1'),
      'or:' || v_bar::text || ':2026-11-20',
      v_t1)),
    format('legacy offer: reminder push, got %s', pg_temp.pushes(v_bar, 'job_offer_reminder'));
  ASSERT pg_temp.offer_state(v_offer) = pg_temp.state('pending', v_t1, NULL, NULL, NULL), 'legacy offer: stamped, pending';

  ASSERT pg_temp.tick(v_t1 + INTERVAL '1 hour') = ARRAY[0, 0, 0, 0], 'legacy offer: second tick does nothing';
  ASSERT pg_temp.tick(v_t1 + INTERVAL '8 days') = ARRAY[0, 0, 0, 0], 'legacy offer: +8 days does nothing';
  ASSERT pg_temp.offer_state(v_offer) = pg_temp.state('pending', v_t1, NULL, NULL, NULL), 'legacy offer: never auto-closed';
  ASSERT pg_temp.push_count(v_biz) = 0, 'legacy offer: nothing to the owner';

  DELETE FROM public.jobs WHERE id = v_job;
  RAISE NOTICE 'ok: legacy offer';
END $$;

DO $$
DECLARE
  v_biz UUID := test.make_user('t6b-biz@test.local', 'business');
  v_bar UUID := test.make_user('t6b-bar@test.local', 'barista');
  v_job UUID := pg_temp.make_job(v_biz, 'Ночная смена');
  v_c TIMESTAMPTZ := '2026-11-21 10:00+03';
  v_offer UUID := pg_temp.make_offer(v_biz, v_bar, v_job, v_c);
  v_t24 TIMESTAMPTZ := v_c + INTERVAL '24 hours';
  v_t72 TIMESTAMPTZ := v_c + INTERVAL '72 hours';
  v_t7d TIMESTAMPTZ := v_c + INTERVAL '7 days';
BEGIN
  UPDATE public.businesses SET name = 'Бодрость' WHERE owner_id = v_biz;
  UPDATE public.barista_profiles SET first_name = 'Анна' WHERE user_id = v_bar;

  ASSERT pg_temp.tick(v_c + INTERVAL '23 hours') = ARRAY[0, 0, 0, 0], 'new offer: nothing at 23h';
  ASSERT pg_temp.tick(v_t24) = ARRAY[0, 0, 1, 0], 'new offer: 24h reminder';
  ASSERT pg_temp.tick(v_c + INTERVAL '25 hours') = ARRAY[0, 0, 0, 0], 'new offer: nothing at 25h';
  ASSERT pg_temp.tick(v_t72) = ARRAY[0, 0, 1, 0], 'new offer: 72h reminder';
  ASSERT pg_temp.pushes(v_bar, 'job_offer_reminder') = jsonb_build_array(
      pg_temp.push('Вам предложили смену', 'Бодрость ждёт ответа: Ночная смена',
        jsonb_build_object('kind', 'job_offer_reminder', 'offerId', v_offer::text, 'count', '1'),
        'or:' || v_bar::text || ':2026-11-22', v_t24),
      pg_temp.push('Вам предложили смену', 'Бодрость ждёт ответа: Ночная смена',
        jsonb_build_object('kind', 'job_offer_reminder', 'offerId', v_offer::text, 'count', '1'),
        'or:' || v_bar::text || ':2026-11-24', v_t72)),
    format('new offer: two reminders with different MSK dates, got %s', pg_temp.pushes(v_bar, 'job_offer_reminder'));
  ASSERT pg_temp.offer_state(v_offer) = pg_temp.state('pending', v_t24, v_t72, NULL, NULL), 'new offer: both stamps';

  ASSERT pg_temp.tick(v_t7d) = ARRAY[0, 0, 0, 1], 'new offer: expired at 7 days';
  ASSERT pg_temp.offer_state(v_offer) = pg_temp.state('expired', v_t24, v_t72, v_t7d, NULL),
    'new offer: status expired, expired_at = p_now, responded_at NULL';
  ASSERT pg_temp.pushes(v_biz, 'job_offer_expired') = jsonb_build_array(pg_temp.push(
      'Нет ответа на предложение',
      'Анна не отвечает на предложение «Ночная смена». Предложите смену другим',
      jsonb_build_object('kind', 'job_offer_expired', 'offerId', v_offer::text, 'jobId', v_job::text),
      'oe:' || v_offer::text,
      v_t7d)),
    format('new offer: job_offer_expired push to the owner with the barista first name, got %s', pg_temp.pushes(v_biz, 'job_offer_expired'));

  ASSERT pg_temp.tick(v_t7d + INTERVAL '1 hour') = ARRAY[0, 0, 0, 0], 'new offer: nothing after expiry';

  DELETE FROM public.jobs WHERE id = v_job;
  RAISE NOTICE 'ok: new offer timeline';
END $$;

DO $$
DECLARE
  v_biz UUID := test.make_user('t6c-biz@test.local', 'business');
  v_biz_cancel UUID := test.make_user('t6c-biz-cancel@test.local', 'business');
  v_bar UUID := test.make_user('t6c-bar@test.local', 'barista');
  v_bar_cancel UUID := test.make_user('t6c-bar-cancel@test.local', 'barista');
  v_job_a UUID := pg_temp.make_job(v_biz, 'Смена А');
  v_job_b UUID := pg_temp.make_job(v_biz, 'Смена Б');
  v_job_cancel UUID := pg_temp.make_job(v_biz_cancel, 'Отменённая смена', 'cancelled');
  v_offer_a UUID := pg_temp.make_offer(v_biz, v_bar, v_job_a, '2026-11-22 10:00+03');
  v_offer_b UUID := pg_temp.make_offer(v_biz, v_bar, v_job_b, '2026-11-22 11:00+03');
  v_offer_cancel UUID := pg_temp.make_offer(v_biz_cancel, v_bar_cancel, v_job_cancel, '2026-11-23 11:00+03');
  v_t TIMESTAMPTZ := '2026-11-23 12:00+03';
BEGIN
  UPDATE public.barista_profiles SET first_name = '  ' WHERE user_id = v_bar_cancel;

  ASSERT pg_temp.tick(v_t) = ARRAY[0, 0, 1, 1], 'offers: one merged reminder and one early expiry';
  ASSERT pg_temp.pushes(v_bar, 'job_offer_reminder') = jsonb_build_array(pg_temp.push(
      '2 предложения ждут ответа',
      'Откройте предложения и ответьте кофейням',
      jsonb_build_object('kind', 'job_offer_reminder', 'count', '2'),
      'or:' || v_bar::text || ':2026-11-23',
      v_t)),
    format('offers: merged reminder without offerId, got %s', pg_temp.pushes(v_bar, 'job_offer_reminder'));
  ASSERT pg_temp.offer_state(v_offer_a) = pg_temp.state('pending', v_t, NULL, NULL, NULL)
     AND pg_temp.offer_state(v_offer_b) = pg_temp.state('pending', v_t, NULL, NULL, NULL),
    'offers: both merged offers stamped';

  ASSERT pg_temp.offer_state(v_offer_cancel) = pg_temp.state('expired', NULL, NULL, v_t, NULL),
    'offers: offer on a cancelled job expired early';
  ASSERT pg_temp.pushes(v_biz_cancel, 'job_offer_expired') = jsonb_build_array(pg_temp.push(
      'Предложение закрыто',
      'Смена «Отменённая смена» больше не доступна',
      jsonb_build_object('kind', 'job_offer_expired', 'offerId', v_offer_cancel::text, 'jobId', v_job_cancel::text),
      'oe:' || v_offer_cancel::text,
      v_t)),
    format('offers: early expiry copy for a job that is no longer live, got %s', pg_temp.pushes(v_biz_cancel, 'job_offer_expired'));
  ASSERT pg_temp.push_count(v_bar_cancel) = 0 AND pg_temp.push_count(v_biz) = 0, 'offers: no stray pushes';

  DELETE FROM public.jobs WHERE id IN (v_job_a, v_job_b, v_job_cancel);
  RAISE NOTICE 'ok: merged offer reminder and early offer expiry';
END $$;

-- ---------------------------------------------------------------------------
-- 7. 145 trigger: expired is not a response; 053: no legacy notification
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_biz UUID := test.make_user('t7-biz@test.local', 'business');
  v_bar1 UUID := test.make_user('t7-bar1@test.local', 'barista');
  v_bar2 UUID := test.make_user('t7-bar2@test.local', 'barista');
  v_job UUID := pg_temp.make_job(v_biz, 'Смена');
  v_app_expire UUID := pg_temp.make_app(v_job, v_bar1, '2026-11-21 10:00+03');
  v_app_accept UUID := pg_temp.make_app(v_job, v_bar2, '2026-11-21 10:00+03');
  v_offer_expire UUID := pg_temp.make_offer(v_biz, v_bar1, v_job, '2026-11-21 10:00+03');
  v_offer_decline UUID := pg_temp.make_offer(v_biz, v_bar2, v_job, '2026-11-21 10:00+03');
  v_notifications BIGINT := (SELECT count(*) FROM public.notifications);
BEGIN
  UPDATE public.applications SET status = 'expired' WHERE id = v_app_expire;
  UPDATE public.applications SET status = 'accepted' WHERE id = v_app_accept;
  UPDATE public.job_offers SET status = 'expired' WHERE id = v_offer_expire;
  UPDATE public.job_offers SET status = 'declined' WHERE id = v_offer_decline;

  ASSERT (
    SELECT ARRAY[
      (SELECT responded_at FROM public.applications WHERE id = v_app_expire),
      (SELECT responded_at FROM public.applications WHERE id = v_app_accept),
      (SELECT responded_at FROM public.job_offers WHERE id = v_offer_expire),
      (SELECT responded_at FROM public.job_offers WHERE id = v_offer_decline)
    ]
  ) = ARRAY[NULL, now(), NULL, now()],
    'set_responded_at_on_status_change: pending -> expired leaves responded_at NULL, other transitions still stamp';

  -- The fixtures carry no 027/051/053 triggers; in production their WHEN
  -- clauses are limited to accepted / rejected / withdrawn, so 'expired' never
  -- fires them. This guards the local schema the same way.
  ASSERT (SELECT count(*) FROM public.notifications) = v_notifications,
    'status -> expired creates no notifications row';

  DELETE FROM public.jobs WHERE id = v_job;
  RAISE NOTICE 'ok: responded_at trigger and no legacy notification';
END $$;

-- ---------------------------------------------------------------------------
-- 8. Modes other than on: nothing stamped, expired or queued; on then catches up
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_biz UUID := test.make_user('t8-biz@test.local', 'business');
  v_bar UUID := test.make_user('t8-bar@test.local', 'barista');
  v_bar_old UUID := test.make_user('t8-bar-old@test.local', 'barista');
  v_job UUID := pg_temp.make_job(v_biz, 'Смена без пушей');
  v_app UUID := pg_temp.make_app(v_job, v_bar, '2026-11-22 10:00+03');
  v_app_old UUID := pg_temp.make_app(v_job, v_bar_old, '2026-11-21 10:00+03');
  v_offer UUID := pg_temp.make_offer(v_biz, v_bar, v_job, '2026-11-22 10:00+03');
  v_t TIMESTAMPTZ := '2026-11-28 12:00+03';
BEGIN
  UPDATE public.feature_flags SET value = '"off"' WHERE key = 'engagement_push_mode';

  ASSERT pg_temp.tick(v_t) = ARRAY[0, 0, 0, 0], 'mode off: tick does nothing';
  ASSERT pg_temp.app_state(v_app) = pg_temp.state('pending', NULL, NULL, NULL, NULL), 'mode off: application untouched';
  ASSERT pg_temp.app_state(v_app_old) = pg_temp.state('pending', NULL, NULL, NULL, NULL), 'mode off: no expiry';
  ASSERT pg_temp.offer_state(v_offer) = pg_temp.state('pending', NULL, NULL, NULL, NULL), 'mode off: offer untouched';

  UPDATE public.feature_flags SET value = '"dry_run"' WHERE key = 'engagement_push_mode';
  ASSERT pg_temp.tick(v_t) = ARRAY[0, 0, 0, 0], 'mode dry_run: tick does nothing';
  UPDATE public.feature_flags SET value = '"admins_only"' WHERE key = 'engagement_push_mode';
  ASSERT pg_temp.tick(v_t) = ARRAY[0, 0, 0, 0], 'mode admins_only: tick does nothing';
  ASSERT pg_temp.push_count(v_biz) = 0 AND pg_temp.push_count(v_bar) = 0 AND pg_temp.push_count(v_bar_old) = 0,
    'non-on modes: nothing queued';

  UPDATE public.feature_flags SET value = '"on"' WHERE key = 'engagement_push_mode';
  ASSERT pg_temp.tick(v_t + INTERVAL '1 hour') = ARRAY[1, 1, 1, 0], 'mode on: the held-back reminders and expiry go out';
  ASSERT pg_temp.app_state(v_app_old) = pg_temp.state('expired', NULL, NULL, v_t + INTERVAL '1 hour', NULL),
    'mode on: 7-day application expired';
  ASSERT pg_temp.push_count(v_biz) = 1 AND pg_temp.push_count(v_bar) = 1 AND pg_temp.push_count(v_bar_old) = 1,
    'mode on: one reminder each to the owner and the barista, one expiry push';

  DELETE FROM public.jobs WHERE id = v_job;
  RAISE NOTICE 'ok: only mode on acts';
END $$;

-- ---------------------------------------------------------------------------
-- 9. Constraint, grants, cron
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_biz UUID := test.make_user('t9-biz@test.local', 'business');
  v_bar UUID := test.make_user('t9-bar@test.local', 'barista');
  v_bar2 UUID := test.make_user('t9-bar2@test.local', 'barista');
  v_job UUID := pg_temp.make_job(v_biz, 'Смена');
  v_rejected BOOLEAN := false;
BEGIN
  INSERT INTO public.applications (job_id, barista_id, status) VALUES (v_job, v_bar, 'expired');
  BEGIN
    INSERT INTO public.applications (job_id, barista_id, status) VALUES (v_job, v_bar2, 'bogus');
  EXCEPTION WHEN check_violation THEN
    v_rejected := true;
  END;
  ASSERT v_rejected, 'applications_status_check: accepts expired, rejects unknown statuses';

  ASSERT (
    SELECT ARRAY[
      has_function_privilege('anon', 'app_internal.process_response_reminders(timestamptz)', 'EXECUTE'),
      has_function_privilege('authenticated', 'app_internal.process_response_reminders(timestamptz)', 'EXECUTE'),
      has_function_privilege('service_role', 'app_internal.process_response_reminders(timestamptz)', 'EXECUTE'),
      has_function_privilege('anon', 'app_internal.reminders_started_at()', 'EXECUTE'),
      has_function_privilege('authenticated', 'app_internal.reminders_started_at()', 'EXECUTE'),
      has_function_privilege('service_role', 'app_internal.reminders_started_at()', 'EXECUTE'),
      has_function_privilege('authenticated', 'app_internal.shift_start_or_null(jsonb)', 'EXECUTE'),
      has_function_privilege('authenticated', 'public.set_responded_at_on_status_change()', 'EXECUTE')
    ]
  ) = ARRAY[false, false, true, false, false, true, false, false],
    'grants: internals for service_role only';

  ASSERT (SELECT ARRAY[j.schedule, j.command] FROM cron.job j WHERE j.jobname = 'process_response_reminders')
    = ARRAY['0 * * * *', 'SELECT app_internal.process_response_reminders();'],
    'cron: process_response_reminders scheduled hourly';

  ASSERT (
    SELECT array_agg(i.indexname::text ORDER BY i.indexname) FROM pg_indexes i
    WHERE i.indexname IN ('applications_pending_created_idx', 'job_offers_pending_created_idx')
  ) = ARRAY['applications_pending_created_idx', 'job_offers_pending_created_idx'],
    'indexes: partial pending indexes exist';

  DELETE FROM public.jobs WHERE id = v_job;
  RAISE NOTICE 'ok: constraint, grants, cron';
END $$;

-- ---------------------------------------------------------------------------
-- 10. 141 guard: a client INSERT cannot pre-set the stamps
-- ---------------------------------------------------------------------------
-- The fixtures carry neither the 141 trigger nor the columns / cooldown
-- function its INSERT branch touches; both are added here (rolled back with
-- the transaction) and the trigger is attached from the 150 function body.
DO $$
DECLARE
  v_biz UUID := test.make_user('t10-biz@test.local', 'business');
  v_bar UUID := test.make_user('t10-bar@test.local', 'barista');
  v_job UUID := pg_temp.make_job(v_biz, 'Смена');
  v_preset TIMESTAMPTZ := '2026-01-01 12:00+03';
  v_app UUID;
BEGIN
  ALTER TABLE public.applications
    ADD COLUMN IF NOT EXISTS completed_by_barista BOOLEAN DEFAULT false,
    ADD COLUMN IF NOT EXISTS completed_by_business BOOLEAN DEFAULT false,
    ADD COLUMN IF NOT EXISTS shift_confirmation_status TEXT,
    ADD COLUMN IF NOT EXISTS shift_confirmation_requested_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS shift_confirmation_responded_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS reminder_24h_notified_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS reminder_3h_notified_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS reminder_1h_no_response_notified_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS cancellation_reason TEXT;
  IF to_regprocedure('public.barista_apply_cooldown_until(uuid)') IS NULL THEN
    CREATE FUNCTION public.barista_apply_cooldown_until(p_barista_id UUID) RETURNS TIMESTAMPTZ
      LANGUAGE sql STABLE AS 'SELECT NULL::timestamptz';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'aa_guard_application_changes_trg') THEN
    CREATE TRIGGER aa_guard_application_changes_trg
      BEFORE INSERT OR UPDATE ON public.applications
      FOR EACH ROW EXECUTE FUNCTION app_internal.guard_application_changes();
  END IF;
  GRANT SELECT, INSERT ON public.applications TO authenticated;
  GRANT USAGE ON SCHEMA auth TO authenticated;

  PERFORM test.act_as(v_bar);
  SET LOCAL ROLE authenticated;
  INSERT INTO public.applications (job_id, barista_id, status, reminder_24h_sent_at, reminder_72h_sent_at, expired_at)
  VALUES (v_job, v_bar, 'expired', v_preset, v_preset, v_preset)
  RETURNING id INTO v_app;
  RESET ROLE;
  PERFORM test.act_as(NULL);

  ASSERT pg_temp.app_state(v_app) = pg_temp.state('pending', NULL, NULL, NULL, NULL),
    'guard_application_changes: client INSERT lands as pending with NULL reminder / expiry stamps';

  REVOKE SELECT, INSERT ON public.applications FROM authenticated;
  DELETE FROM public.jobs WHERE id = v_job;
  RAISE NOTICE 'ok: 141 guard forces the stamps to NULL on insert';
END $$;

-- Re-applying the migration keeps the launch marker (ON CONFLICT DO NOTHING).
\ir ../../migrations/150_response_reminders.sql

DO $$
BEGIN
  ASSERT app_internal.reminders_started_at() = pg_temp.marker(), 're-apply: launch marker untouched';
  ASSERT (SELECT count(*) FROM cron.job j WHERE j.jobname = 'process_response_reminders') = 1, 're-apply: one cron row';
  RAISE NOTICE 'ok: migration re-applies cleanly';
END $$;

ROLLBACK;

-- Tests for 149_new_job_nearby.sql. Run through run.sh (fixtures + migrations
-- are applied first). One transaction, rolled back at the end.
--
-- Reference moment v_now = today 12:00 MSK (stored in test_ctx): the p_now
-- driven functions and the now()-driven count_job_audience RPC must agree on
-- what is "recent", so every relative timestamp keeps a margin wider than the
-- 12 h gap between v_now and the session clock. Shift dates are relative to
-- the Moscow date of v_now; the exact-text checks use a pinned p_now instead.
--
-- The fixture has neither compute_shift_start (129) nor
-- barista_apply_cooldown_until (075): both are created here only when
-- missing. The cooldown stub reads test.apply_cooldowns so one barista can be
-- put on cooldown.
BEGIN;

SET LOCAL timezone = 'UTC';

CREATE TEMP TABLE test_ids (k TEXT PRIMARY KEY, id UUID NOT NULL) ON COMMIT DROP;
CREATE TEMP TABLE test_ctx (k TEXT PRIMARY KEY, ts TIMESTAMPTZ NOT NULL) ON COMMIT DROP;

CREATE FUNCTION pg_temp.tid(p_key TEXT) RETURNS UUID LANGUAGE sql STABLE
AS $$ SELECT id FROM test_ids WHERE k = p_key $$;

CREATE FUNCTION pg_temp.t_now() RETURNS TIMESTAMPTZ LANGUAGE sql STABLE
AS $$ SELECT ts FROM test_ctx WHERE k = 'now' $$;

CREATE FUNCTION pg_temp.msk_date(p_ts TIMESTAMPTZ) RETURNS DATE LANGUAGE sql IMMUTABLE
AS $$ SELECT (p_ts AT TIME ZONE 'Europe/Moscow')::date $$;

CREATE FUNCTION pg_temp.shift(p_date DATE, p_time TEXT DEFAULT '09:00') RETURNS JSONB LANGUAGE sql IMMUTABLE
AS $$ SELECT jsonb_build_object('startDate', p_date::TEXT, 'startTime', p_time) $$;

CREATE FUNCTION pg_temp.make_branch(p_owner UUID, p_city TEXT, p_station TEXT, p_active BOOLEAN DEFAULT true)
RETURNS UUID LANGUAGE sql
AS $$
  INSERT INTO public.branches (business_id, name, city, metro_station, is_active)
  SELECT b.id, COALESCE(p_station, p_city), p_city, p_station, p_active
  FROM public.businesses b WHERE b.owner_id = p_owner
  RETURNING id;
$$;

CREATE FUNCTION pg_temp.make_job(p_branch UUID, p_shift JSONB, p_comp JSONB, p_status TEXT DEFAULT 'open')
RETURNS UUID LANGUAGE sql
AS $$
  INSERT INTO public.jobs (business_id, business_owner_id, branch_id, status, shift_details, compensation)
  SELECT br.business_id, b.owner_id, br.id, p_status, p_shift, p_comp
  FROM public.branches br JOIN public.businesses b ON b.id = br.business_id
  WHERE br.id = p_branch
  RETURNING id;
$$;

CREATE FUNCTION pg_temp.emails_of(p_ids UUID[]) RETURNS TEXT[] LANGUAGE sql STABLE
AS $$ SELECT COALESCE(array_agg(u.email ORDER BY u.email), '{}') FROM public.users u WHERE u.id = ANY (p_ids) $$;

CREATE FUNCTION pg_temp.audience(p_job UUID, p_now TIMESTAMPTZ) RETURNS TEXT[] LANGUAGE sql STABLE
AS $$ SELECT pg_temp.emails_of(ARRAY(SELECT a.user_id FROM app_internal.job_nearby_audience(p_job, p_now) a)) $$;

-- Distinct rendered text of an audience: [{title, body, data}].
CREATE FUNCTION pg_temp.rendered(p_job UUID, p_now TIMESTAMPTZ) RETURNS JSONB LANGUAGE sql STABLE
AS $$
  SELECT COALESCE(jsonb_agg(DISTINCT jsonb_build_object('title', a.title, 'body', a.body, 'data', a.data)), '[]'::jsonb)
  FROM app_internal.job_nearby_audience(p_job, p_now) a
$$;

CREATE FUNCTION pg_temp.queue_row(p_job UUID) RETURNS JSONB LANGUAGE sql STABLE
AS $$
  SELECT to_jsonb(q) - 'job_id' - 'enqueued_at'
  FROM app_internal.job_fanout_queue q WHERE q.job_id = p_job
$$;

-- ---------------------------------------------------------------------------
-- 0. Production helpers missing from the fixture
-- ---------------------------------------------------------------------------
CREATE TABLE test.apply_cooldowns (barista_id UUID PRIMARY KEY, until_at TIMESTAMPTZ NOT NULL);

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

  IF to_regprocedure('app_internal.barista_apply_cooldown_until(uuid)') IS NULL THEN
    EXECUTE $def$
      CREATE FUNCTION app_internal.barista_apply_cooldown_until(p_barista_id UUID)
      RETURNS TIMESTAMPTZ
      LANGUAGE sql STABLE
      AS $f$ SELECT c.until_at FROM test.apply_cooldowns c WHERE c.barista_id = p_barista_id $f$
    $def$;
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 1. ru_short_date
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  ASSERT (SELECT ARRAY[
    app_internal.ru_short_date('2026-01-01'),
    app_internal.ru_short_date('2026-11-28'),
    app_internal.ru_short_date('2026-05-05'),
    app_internal.ru_short_date('2026-12-31')
  ]) = ARRAY['1 янв', '28 ноя', '5 мая', '31 дек'],
    'ru_short_date renders day + genitive month abbreviation';
  ASSERT app_internal.ru_short_date(NULL) IS NULL, 'ru_short_date(NULL) is NULL';
  RAISE NOTICE 'ok: ru_short_date';
END $$;

-- ---------------------------------------------------------------------------
-- 2. Fixture data
-- ---------------------------------------------------------------------------
-- Baristas (spb unless noted; make_user gives completeness 50, looking = true,
-- every station list is {Чернышевская} unless noted; "seen" = user_activity):
--   included for job_main: a seen 1 d, b {__any__}, g seen 59 d,
--                          n accepted shift on another date
--   excluded: c {} no stations, d moscow, e completeness 29, f seen 61 d,
--             h not looking, i banned, j inactive, k admin, l applied (pending),
--             q applied (withdrawn), m accepted shift on the same date,
--             o on apply cooldown, p never seen
-- Businesses: biz1 spb (Чернышевская / Площадь Восстания / no station /
--   inactive Чернышевская / moscow Арбатская), biz3 not accepting
--   (Чернышевская), adm admin owner (Чернышевская).
DO $$
DECLARE
  v_now TIMESTAMPTZ := ((now() AT TIME ZONE 'Europe/Moscow')::date + TIME '12:00') AT TIME ZONE 'Europe/Moscow';
  v_u UUID;
  k TEXT;
BEGIN
  INSERT INTO test_ctx VALUES ('now', v_now);
  UPDATE public.feature_flags SET value = '"on"' WHERE key = 'engagement_push_mode';

  FOREACH k IN ARRAY ARRAY['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'l', 'm', 'n', 'o', 'p', 'q'] LOOP
    v_u := test.make_user('nj-' || k || '@test.local', 'barista');
    INSERT INTO test_ids VALUES ('bar_' || k, v_u);
  END LOOP;
  v_u := test.make_user('nj-k@test.local', 'barista', true);
  INSERT INTO test_ids VALUES ('bar_k', v_u);

  UPDATE public.barista_profiles SET preferred_metro_stations = '{Чернышевская}'
   WHERE user_id IN (SELECT t.id FROM test_ids t WHERE t.k LIKE 'bar_%');
  UPDATE public.barista_profiles SET preferred_metro_stations = '{__any__}' WHERE user_id = pg_temp.tid('bar_b');
  UPDATE public.barista_profiles SET preferred_metro_stations = '{}' WHERE user_id = pg_temp.tid('bar_c');
  UPDATE public.barista_profiles SET city = 'moscow' WHERE user_id = pg_temp.tid('bar_d');
  UPDATE public.barista_profiles SET profile_completeness = 29 WHERE user_id = pg_temp.tid('bar_e');
  UPDATE public.barista_profiles SET is_actively_looking = false WHERE user_id = pg_temp.tid('bar_h');
  UPDATE public.users SET banned_at = v_now - INTERVAL '1 day' WHERE id = pg_temp.tid('bar_i');
  UPDATE public.users SET is_active = false WHERE id = pg_temp.tid('bar_j');

  INSERT INTO public.user_activity (user_id, last_seen_at)
  SELECT pg_temp.tid('bar_' || x), v_now - INTERVAL '1 day'
  FROM unnest(ARRAY['a', 'b', 'c', 'd', 'e', 'h', 'i', 'j', 'k', 'l', 'm', 'n', 'o', 'q']) AS x;
  INSERT INTO public.user_activity (user_id, last_seen_at) VALUES
    (pg_temp.tid('bar_f'), v_now - INTERVAL '61 days'),
    (pg_temp.tid('bar_g'), v_now - INTERVAL '59 days');

  INSERT INTO test.apply_cooldowns VALUES (pg_temp.tid('bar_o'), '2099-01-01 00:00+03');

  v_u := test.make_user('nj-biz1@test.local', 'business');
  INSERT INTO test_ids VALUES ('biz_1', v_u);
  v_u := test.make_user('nj-biz3@test.local', 'business');
  INSERT INTO test_ids VALUES ('biz_3', v_u);
  UPDATE public.businesses SET is_accepting_applications = false WHERE owner_id = v_u;
  v_u := test.make_user('nj-adm@test.local', 'business', true);
  INSERT INTO test_ids VALUES ('adm', v_u);

  INSERT INTO test_ids VALUES
    ('br_cher', pg_temp.make_branch(pg_temp.tid('biz_1'), 'spb', 'Чернышевская')),
    ('br_plo', pg_temp.make_branch(pg_temp.tid('biz_1'), 'spb', 'Площадь Восстания')),
    ('br_none', pg_temp.make_branch(pg_temp.tid('biz_1'), 'spb', NULL)),
    ('br_inactive', pg_temp.make_branch(pg_temp.tid('biz_1'), 'spb', 'Чернышевская', false)),
    ('br_msk', pg_temp.make_branch(pg_temp.tid('biz_1'), 'moscow', 'Арбатская')),
    ('br_3', pg_temp.make_branch(pg_temp.tid('biz_3'), 'spb', 'Чернышевская')),
    ('br_adm', pg_temp.make_branch(pg_temp.tid('adm'), 'spb', 'Чернышевская'));
END $$;

-- ---------------------------------------------------------------------------
-- 3. zz_job_fanout_enqueue trigger
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_date DATE := pg_temp.msk_date(pg_temp.t_now());
  v_open UUID;
  v_filled UUID;
  v_before TIMESTAMPTZ;
BEGIN
  v_open := pg_temp.make_job(pg_temp.tid('br_cher'), pg_temp.shift(v_date + 3), '{"type":"hourly","amount":600}');
  ASSERT pg_temp.queue_row(v_open) = '{"processed_at": null, "audience_count": null, "skipped_reason": null}'::jsonb,
    'INSERT with status open queues the job';

  v_filled := pg_temp.make_job(pg_temp.tid('br_cher'), pg_temp.shift(v_date + 3), '{"type":"hourly","amount":600}', 'filled');
  ASSERT pg_temp.queue_row(v_filled) IS NULL, 'INSERT with status filled queues nothing';

  UPDATE public.jobs SET status = 'open' WHERE id = v_filled;
  ASSERT pg_temp.queue_row(v_filled) = '{"processed_at": null, "audience_count": null, "skipped_reason": null}'::jsonb,
    'UPDATE filled -> open queues the job';

  UPDATE app_internal.job_fanout_queue
     SET processed_at = pg_temp.t_now(), audience_count = 7, skipped_reason = 'no_audience',
         enqueued_at = pg_temp.t_now() - INTERVAL '1 hour'
   WHERE job_id = v_open;
  v_before := pg_temp.t_now() - INTERVAL '1 hour';

  UPDATE public.jobs SET title = 'Другое название' WHERE id = v_open;
  UPDATE public.jobs SET status = 'open' WHERE id = v_open;
  ASSERT (SELECT ARRAY[q.enqueued_at, q.processed_at] FROM app_internal.job_fanout_queue q WHERE q.job_id = v_open)
       = ARRAY[v_before, pg_temp.t_now()],
    'title change and open -> open leave the processed row untouched';

  UPDATE public.jobs SET status = 'filled' WHERE id = v_open;
  ASSERT (SELECT ARRAY[q.enqueued_at, q.processed_at] FROM app_internal.job_fanout_queue q WHERE q.job_id = v_open)
       = ARRAY[v_before, pg_temp.t_now()],
    'open -> filled leaves the processed row untouched';

  UPDATE public.jobs SET status = 'open' WHERE id = v_open;
  ASSERT (SELECT to_jsonb(q) - 'job_id' FROM app_internal.job_fanout_queue q WHERE q.job_id = v_open)
       = jsonb_build_object('enqueued_at', now(), 'processed_at', NULL, 'audience_count', NULL, 'skipped_reason', NULL),
    're-open resets the queue row for another fan-out';

  DELETE FROM public.jobs WHERE id IN (v_open, v_filled);
  ASSERT (SELECT count(*) FROM app_internal.job_fanout_queue) = 0, 'queue rows follow their job (ON DELETE CASCADE)';
  RAISE NOTICE 'ok: zz_job_fanout_enqueue trigger';
END $$;

-- ---------------------------------------------------------------------------
-- 4. job_nearby_audience: recipients
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_now TIMESTAMPTZ := pg_temp.t_now();
  v_date DATE := pg_temp.msk_date(v_now);
  v_main UUID;
  v_same UUID;
  v_other UUID;
BEGIN
  v_main := pg_temp.make_job(pg_temp.tid('br_cher'), pg_temp.shift(v_date + 3), '{"type":"hourly","amount":600}');
  INSERT INTO test_ids VALUES ('job_main', v_main);

  -- Accepted shifts of m (same Moscow day) and n (the day after); both jobs
  -- are filled so the trigger does not queue them.
  v_same := pg_temp.make_job(pg_temp.tid('br_plo'), pg_temp.shift(v_date + 3, '18:00'), '{"type":"hourly","amount":500}', 'filled');
  v_other := pg_temp.make_job(pg_temp.tid('br_plo'), pg_temp.shift(v_date + 4, '09:00'), '{"type":"hourly","amount":500}', 'filled');
  INSERT INTO public.applications (job_id, barista_id, status) VALUES
    (v_same, pg_temp.tid('bar_m'), 'accepted'),
    (v_other, pg_temp.tid('bar_n'), 'accepted'),
    (v_main, pg_temp.tid('bar_l'), 'pending'),
    (v_main, pg_temp.tid('bar_q'), 'withdrawn');

  ASSERT pg_temp.audience(v_main, v_now)
       = ARRAY['nj-a@test.local', 'nj-b@test.local', 'nj-g@test.local', 'nj-n@test.local'],
    format('audience of job_main: %s', pg_temp.audience(v_main, v_now));

  ASSERT pg_temp.audience(v_main, v_now + INTERVAL '2 days') = ARRAY['nj-a@test.local', 'nj-b@test.local', 'nj-n@test.local'],
    'g (seen 59 days before v_now) drops out two days later; o is still on cooldown';

  DELETE FROM test.apply_cooldowns WHERE barista_id = pg_temp.tid('bar_o');
  ASSERT pg_temp.audience(v_main, v_now)
       = ARRAY['nj-a@test.local', 'nj-b@test.local', 'nj-g@test.local', 'nj-n@test.local', 'nj-o@test.local'],
    'o is included once the cooldown is gone';
  INSERT INTO test.apply_cooldowns VALUES (pg_temp.tid('bar_o'), '2099-01-01 00:00+03');

  RAISE NOTICE 'ok: job_nearby_audience recipients (station, __any__, exclusions, same-day accepted shift, cooldown)';
END $$;

-- ---------------------------------------------------------------------------
-- 5. job_nearby_audience: rendered text (pinned p_now = 2026-11-25 12:00 MSK)
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_pinned TIMESTAMPTZ := '2026-11-25 12:00+03';
  v_shift JSONB := '{"startDate":"2026-11-28","startTime":"09:00"}';
  v_job UUID;
  v_jobs UUID[] := '{}';
  v_title TEXT := 'Новая смена рядом';
BEGIN
  -- hourly
  v_job := pg_temp.make_job(pg_temp.tid('br_cher'), v_shift, '{"type":"hourly","amount":600}');
  v_jobs := v_jobs || v_job;
  ASSERT pg_temp.rendered(v_job, v_pinned) = jsonb_build_array(jsonb_build_object(
      'title', v_title,
      'body', 'Новая смена у м. Чернышевская · 28 ноя, 600 ₽/ч',
      'data', jsonb_build_object('kind', 'new_job_nearby', 'jobId', v_job::TEXT, 'city', 'spb', 'metroStation', 'Чернышевская'))),
    format('hourly body / data: %s', pg_temp.rendered(v_job, v_pinned));

  -- daily
  v_job := pg_temp.make_job(pg_temp.tid('br_cher'), v_shift, '{"type":"daily","amount":5000}');
  v_jobs := v_jobs || v_job;
  ASSERT pg_temp.rendered(v_job, v_pinned)->0->>'body' = 'Новая смена у м. Чернышевская · 28 ноя, 5000 ₽/день', 'daily rate';

  -- fixed, amount as a string
  v_job := pg_temp.make_job(pg_temp.tid('br_cher'), v_shift, '{"type":"fixed","amount":"3000"}');
  v_jobs := v_jobs || v_job;
  ASSERT pg_temp.rendered(v_job, v_pinned)->0->>'body' = 'Новая смена у м. Чернышевская · 28 ноя, 3000 ₽', 'fixed rate from a string amount';

  -- no compensation
  v_job := pg_temp.make_job(pg_temp.tid('br_cher'), v_shift, NULL);
  v_jobs := v_jobs || v_job;
  ASSERT pg_temp.rendered(v_job, v_pinned)->0->>'body' = 'Новая смена у м. Чернышевская · 28 ноя', 'missing compensation: no rate, no trailing comma';

  -- non-numeric amount
  v_job := pg_temp.make_job(pg_temp.tid('br_cher'), v_shift, '{"type":"hourly","amount":"договорная"}');
  v_jobs := v_jobs || v_job;
  ASSERT pg_temp.rendered(v_job, v_pinned)->0->>'body' = 'Новая смена у м. Чернышевская · 28 ноя', 'non-numeric amount: rate omitted';

  -- startDate as the ISO instant of Moscow midnight (129): still 28 Nov
  v_job := pg_temp.make_job(pg_temp.tid('br_cher'), '{"startDate":"2026-11-27T21:00:00.000Z","startTime":"09:00"}', '{"type":"hourly","amount":600}');
  v_jobs := v_jobs || v_job;
  ASSERT pg_temp.rendered(v_job, v_pinned)->0->>'body' = 'Новая смена у м. Чернышевская · 28 ноя, 600 ₽/ч', 'ISO-instant startDate is read as a Moscow day';

  -- no shift details at all: not past, no date in the text
  v_job := pg_temp.make_job(pg_temp.tid('br_cher'), NULL, '{"type":"hourly","amount":600}');
  v_jobs := v_jobs || v_job;
  ASSERT pg_temp.rendered(v_job, v_pinned)->0->>'body' = 'Новая смена у м. Чернышевская · 600 ₽/ч', 'missing shift details: date omitted';

  -- permanent vacancy: «вакансия» instead of «смена» in title and body
  v_job := pg_temp.make_job(pg_temp.tid('br_cher'), v_shift, '{"type":"hourly","amount":600}');
  v_jobs := v_jobs || v_job;
  UPDATE public.jobs SET job_type = 'permanent' WHERE id = v_job;
  ASSERT pg_temp.rendered(v_job, v_pinned) = jsonb_build_array(jsonb_build_object(
      'title', 'Новая вакансия рядом',
      'body', 'Новая вакансия у м. Чернышевская · 28 ноя, 600 ₽/ч',
      'data', jsonb_build_object('kind', 'new_job_nearby', 'jobId', v_job::TEXT, 'city', 'spb', 'metroStation', 'Чернышевская'))),
    format('permanent job title / body: %s', pg_temp.rendered(v_job, v_pinned));

  v_job := pg_temp.make_job(pg_temp.tid('br_none'), v_shift, NULL);
  v_jobs := v_jobs || v_job;
  UPDATE public.jobs SET job_type = 'permanent' WHERE id = v_job;
  ASSERT pg_temp.rendered(v_job, v_pinned)->0->>'body' = 'Новая вакансия в Петербурге · 28 ноя', 'permanent job without a station: city form';

  -- branch without a station: city form, only __any__ baristas
  v_job := pg_temp.make_job(pg_temp.tid('br_none'), v_shift, '{"type":"hourly","amount":600}');
  v_jobs := v_jobs || v_job;
  ASSERT pg_temp.audience(v_job, v_pinned) = ARRAY['nj-b@test.local'],
    format('no-station branch reaches only __any__ baristas: %s', pg_temp.audience(v_job, v_pinned));
  ASSERT pg_temp.rendered(v_job, v_pinned) = jsonb_build_array(jsonb_build_object(
      'title', v_title,
      'body', 'Новая смена в Петербурге · 28 ноя, 600 ₽/ч',
      'data', jsonb_build_object('kind', 'new_job_nearby', 'jobId', v_job::TEXT, 'city', 'spb'))),
    format('no-station body / data: %s', pg_temp.rendered(v_job, v_pinned));

  -- Shift start 28 Nov 09:00 MSK against p_now one second later / exactly then.
  ASSERT pg_temp.audience(v_job, '2026-11-28 09:00:01+03') = '{}', 'shift start < p_now: no audience';
  ASSERT pg_temp.audience(v_job, '2026-11-28 09:00:00+03') = ARRAY['nj-b@test.local'], 'shift start = p_now is not past';

  DELETE FROM public.jobs WHERE id = ANY (v_jobs);
  RAISE NOTICE 'ok: rendered text (hourly / daily / fixed / missing / non-numeric, ISO date, permanent vacancy, no station, shift_past boundary)';
END $$;

-- ---------------------------------------------------------------------------
-- 6. process_job_fanout
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_now TIMESTAMPTZ := pg_temp.t_now();
  v_date DATE := pg_temp.msk_date(v_now);
  v_day TEXT := v_date::TEXT;
  v_main UUID := pg_temp.tid('job_main');
  v_main2 UUID;
  v_admin UUID;
  v_notacc UUID;
  v_inactive UUID;
  v_past UUID;
  v_cancel UUID;
  v_noaud UUID;
  v_result RECORD;
  v_actual JSONB;
  v_expected JSONB;
  v_body_main TEXT := 'Новая смена у м. Чернышевская · ' || app_internal.ru_short_date(v_date + 3) || ', 600 ₽/ч';
  v_body_main2 TEXT := 'Новая смена у м. Чернышевская · ' || app_internal.ru_short_date(v_date + 5) || ', 650 ₽/ч';
  v_data_main JSONB;
  v_data_main2 JSONB;
BEGIN
  v_main2 := pg_temp.make_job(pg_temp.tid('br_cher'), pg_temp.shift(v_date + 5), '{"type":"hourly","amount":650}');
  v_admin := pg_temp.make_job(pg_temp.tid('br_adm'), pg_temp.shift(v_date + 3), '{"type":"hourly","amount":600}');
  v_notacc := pg_temp.make_job(pg_temp.tid('br_3'), pg_temp.shift(v_date + 3), '{"type":"hourly","amount":600}');
  v_inactive := pg_temp.make_job(pg_temp.tid('br_inactive'), pg_temp.shift(v_date + 3), '{"type":"hourly","amount":600}');
  v_past := pg_temp.make_job(pg_temp.tid('br_cher'), pg_temp.shift(v_date - 1), '{"type":"hourly","amount":600}');
  v_cancel := pg_temp.make_job(pg_temp.tid('br_cher'), pg_temp.shift(v_date + 3), '{"type":"hourly","amount":600}');
  v_noaud := pg_temp.make_job(pg_temp.tid('br_msk'), pg_temp.shift(v_date + 3), '{"type":"hourly","amount":600}');
  UPDATE public.jobs SET status = 'cancelled' WHERE id = v_cancel;

  v_data_main := jsonb_build_object('kind', 'new_job_nearby', 'jobId', v_main::TEXT, 'city', 'spb', 'metroStation', 'Чернышевская');
  v_data_main2 := jsonb_build_object('kind', 'new_job_nearby', 'jobId', v_main2::TEXT, 'city', 'spb', 'metroStation', 'Чернышевская');

  ASSERT (SELECT count(*) FROM app_internal.job_fanout_queue WHERE processed_at IS NULL) = 8, 'eight jobs wait in the queue';
  -- All rows share the transaction's now(); pin the order so job_main is fanned out first.
  UPDATE app_internal.job_fanout_queue SET enqueued_at = v_now - INTERVAL '2 minutes' WHERE job_id = v_main;
  UPDATE app_internal.job_fanout_queue SET enqueued_at = v_now - INTERVAL '1 minute' WHERE job_id = v_main2;

  UPDATE public.feature_flags SET value = '"off"' WHERE key = 'engagement_push_mode';
  SELECT * INTO v_result FROM app_internal.process_job_fanout(v_now);
  ASSERT (v_result.jobs_processed, v_result.pushes_enqueued) = (8, 0),
    format('mode off: jobs are processed but nothing is queued, got %s', to_jsonb(v_result));
  ASSERT (SELECT count(*) FROM app_internal.engagement_pushes WHERE kind = 'new_job_nearby') = 0, 'mode off: no pushes';
  ASSERT pg_temp.queue_row(v_main) = jsonb_build_object('processed_at', v_now, 'audience_count', 4, 'skipped_reason', NULL),
    'mode off still records the audience size';

  -- Re-queue everything and run for real.
  UPDATE app_internal.job_fanout_queue SET processed_at = NULL, audience_count = NULL, skipped_reason = NULL;
  UPDATE public.feature_flags SET value = '"on"' WHERE key = 'engagement_push_mode';
  SELECT * INTO v_result FROM app_internal.process_job_fanout(v_now);
  -- job_main2 also reaches l and q (they applied to job_main only) and m
  -- (accepted shift on another day): 7 recipients, 3 of them new today.
  ASSERT (v_result.jobs_processed, v_result.pushes_enqueued) = (8, 7),
    format('8 jobs processed, 7 pushes (a b g n from job_main, l m q from job_main2), got %s', to_jsonb(v_result));

  SELECT jsonb_object_agg(
           CASE q.job_id
             WHEN v_main THEN 'main' WHEN v_main2 THEN 'main2' WHEN v_admin THEN 'admin'
             WHEN v_notacc THEN 'notacc' WHEN v_inactive THEN 'inactive' WHEN v_past THEN 'past'
             WHEN v_cancel THEN 'cancel' WHEN v_noaud THEN 'noaud'
           END,
           jsonb_build_object('processed_at', q.processed_at, 'audience_count', q.audience_count, 'skipped_reason', q.skipped_reason))
    INTO v_actual
  FROM app_internal.job_fanout_queue q;
  v_expected := jsonb_build_object(
    'main',     jsonb_build_object('processed_at', v_now, 'audience_count', 4, 'skipped_reason', NULL),
    'main2',    jsonb_build_object('processed_at', v_now, 'audience_count', 7, 'skipped_reason', NULL),
    'admin',    jsonb_build_object('processed_at', v_now, 'audience_count', 0, 'skipped_reason', 'admin_owner'),
    'notacc',   jsonb_build_object('processed_at', v_now, 'audience_count', 0, 'skipped_reason', 'not_accepting'),
    'inactive', jsonb_build_object('processed_at', v_now, 'audience_count', 0, 'skipped_reason', 'branch_inactive'),
    'past',     jsonb_build_object('processed_at', v_now, 'audience_count', 0, 'skipped_reason', 'shift_past'),
    'cancel',   jsonb_build_object('processed_at', v_now, 'audience_count', 0, 'skipped_reason', 'not_open'),
    'noaud',    jsonb_build_object('processed_at', v_now, 'audience_count', 0, 'skipped_reason', 'no_audience')
  );
  ASSERT v_actual = v_expected,
    'queue after processing: ' || E'\nactual:   ' || v_actual::TEXT || E'\nexpected: ' || v_expected::TEXT;

  SELECT jsonb_agg(jsonb_build_object(
           'email', u.email, 'kind', ep.kind, 'title', ep.title, 'body', ep.body, 'data', ep.data,
           'dedupe_key', ep.dedupe_key, 'send_after', ep.send_after,
           'queued', ep.sent_at IS NULL AND ep.skipped_reason IS NULL) ORDER BY u.email)
    INTO v_actual
  FROM app_internal.engagement_pushes ep
  JOIN public.users u ON u.id = ep.user_id
  WHERE ep.kind = 'new_job_nearby';
  v_expected := jsonb_build_array(
    jsonb_build_object('email', 'nj-a@test.local', 'kind', 'new_job_nearby', 'title', 'Новая смена рядом',
      'body', v_body_main, 'data', v_data_main, 'dedupe_key', 'nj:' || pg_temp.tid('bar_a') || ':' || v_day,
      'send_after', v_now, 'queued', true),
    jsonb_build_object('email', 'nj-b@test.local', 'kind', 'new_job_nearby', 'title', 'Новая смена рядом',
      'body', v_body_main, 'data', v_data_main, 'dedupe_key', 'nj:' || pg_temp.tid('bar_b') || ':' || v_day,
      'send_after', v_now, 'queued', true),
    jsonb_build_object('email', 'nj-g@test.local', 'kind', 'new_job_nearby', 'title', 'Новая смена рядом',
      'body', v_body_main, 'data', v_data_main, 'dedupe_key', 'nj:' || pg_temp.tid('bar_g') || ':' || v_day,
      'send_after', v_now, 'queued', true),
    jsonb_build_object('email', 'nj-l@test.local', 'kind', 'new_job_nearby', 'title', 'Новая смена рядом',
      'body', v_body_main2, 'data', v_data_main2, 'dedupe_key', 'nj:' || pg_temp.tid('bar_l') || ':' || v_day,
      'send_after', v_now, 'queued', true),
    jsonb_build_object('email', 'nj-m@test.local', 'kind', 'new_job_nearby', 'title', 'Новая смена рядом',
      'body', v_body_main2, 'data', v_data_main2, 'dedupe_key', 'nj:' || pg_temp.tid('bar_m') || ':' || v_day,
      'send_after', v_now, 'queued', true),
    jsonb_build_object('email', 'nj-n@test.local', 'kind', 'new_job_nearby', 'title', 'Новая смена рядом',
      'body', v_body_main, 'data', v_data_main, 'dedupe_key', 'nj:' || pg_temp.tid('bar_n') || ':' || v_day,
      'send_after', v_now, 'queued', true),
    jsonb_build_object('email', 'nj-q@test.local', 'kind', 'new_job_nearby', 'title', 'Новая смена рядом',
      'body', v_body_main2, 'data', v_data_main2, 'dedupe_key', 'nj:' || pg_temp.tid('bar_q') || ':' || v_day,
      'send_after', v_now, 'queued', true)
  );
  ASSERT v_actual = v_expected,
    'queued pushes: ' || E'\nactual:   ' || v_actual::TEXT || E'\nexpected: ' || v_expected::TEXT;

  SELECT * INTO v_result FROM app_internal.process_job_fanout(v_now);
  ASSERT (v_result.jobs_processed, v_result.pushes_enqueued) = (0, 0), 'an empty queue processes nothing';

  -- Re-opening job_main2 the next Moscow day: new dedupe keys for all 7
  -- (g, seen 59 days before v_now, is exactly 60 days old then and still in).
  UPDATE public.jobs SET status = 'filled' WHERE id = v_main2;
  UPDATE public.jobs SET status = 'open' WHERE id = v_main2;
  SELECT * INTO v_result FROM app_internal.process_job_fanout(v_now + INTERVAL '1 day');
  ASSERT (v_result.jobs_processed, v_result.pushes_enqueued) = (1, 7),
    format('re-opened job on the next Moscow day reaches all 7 again, got %s', to_jsonb(v_result));
  ASSERT (SELECT array_agg(ep.dedupe_key ORDER BY ep.dedupe_key) FROM app_internal.engagement_pushes ep
          WHERE ep.kind = 'new_job_nearby' AND ep.data->>'jobId' = v_main2::TEXT AND ep.send_after = v_now + INTERVAL '1 day')
       = (SELECT array_agg(s.key ORDER BY s.key)
          FROM (SELECT 'nj:' || pg_temp.tid('bar_' || x) || ':' || (v_date + 1)::TEXT AS key
                FROM unnest(ARRAY['a', 'b', 'g', 'l', 'm', 'n', 'q']) AS x) s),
    'next-day dedupe keys carry the next Moscow date';

  DELETE FROM public.jobs WHERE id IN (v_main2, v_admin, v_notacc, v_inactive, v_past, v_cancel, v_noaud);
  RAISE NOTICE 'ok: process_job_fanout (mode off, skip reasons, audience_count, dedupe per Moscow day, queued rows)';
END $$;

-- ---------------------------------------------------------------------------
-- 7. count_job_audience (now()-based, caller checks)
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_main UUID := pg_temp.tid('job_main');
  v_denied INT := 0;
BEGIN
  PERFORM test.act_as(pg_temp.tid('biz_1'));
  ASSERT public.count_job_audience(v_main) = 4, 'owner sees the audience size';

  PERFORM test.act_as(pg_temp.tid('adm'));
  ASSERT public.count_job_audience(v_main) = 4, 'admin sees the audience size';

  PERFORM test.act_as(pg_temp.tid('biz_3'));
  BEGIN
    PERFORM public.count_job_audience(v_main);
  EXCEPTION WHEN insufficient_privilege THEN
    v_denied := v_denied + 1;
  END;

  PERFORM test.act_as(pg_temp.tid('bar_a'));
  BEGIN
    PERFORM public.count_job_audience(v_main);
  EXCEPTION WHEN insufficient_privilege THEN
    v_denied := v_denied + 1;
  END;

  PERFORM test.act_as(NULL);
  BEGIN
    PERFORM public.count_job_audience(v_main);
  EXCEPTION WHEN insufficient_privilege THEN
    v_denied := v_denied + 1;
  END;

  PERFORM test.act_as(pg_temp.tid('biz_1'));
  BEGIN
    PERFORM public.count_job_audience(uuid_generate_v4());
  EXCEPTION WHEN insufficient_privilege THEN
    v_denied := v_denied + 1;
  END;
  ASSERT v_denied = 4, format('another business, a barista, anon and an unknown job all get 42501 (got %s of 4)', v_denied);

  ASSERT (SELECT count(*) FROM app_internal.engagement_pushes) = 14, 'count_job_audience queues nothing';
  PERFORM test.act_as(NULL);
  RAISE NOTICE 'ok: count_job_audience (owner, admin, 42501 cases, read-only)';
END $$;

-- ---------------------------------------------------------------------------
-- 8. Grants, cron, trigger definition
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  ASSERT (
    SELECT ARRAY[
      has_function_privilege('anon', 'app_internal.job_nearby_audience(uuid,timestamptz)', 'EXECUTE'),
      has_function_privilege('authenticated', 'app_internal.job_nearby_audience(uuid,timestamptz)', 'EXECUTE'),
      has_function_privilege('service_role', 'app_internal.job_nearby_audience(uuid,timestamptz)', 'EXECUTE'),
      has_function_privilege('anon', 'app_internal.job_fanout_skip_reason(uuid,timestamptz)', 'EXECUTE'),
      has_function_privilege('authenticated', 'app_internal.job_fanout_skip_reason(uuid,timestamptz)', 'EXECUTE'),
      has_function_privilege('service_role', 'app_internal.job_fanout_skip_reason(uuid,timestamptz)', 'EXECUTE'),
      has_function_privilege('anon', 'app_internal.process_job_fanout(timestamptz)', 'EXECUTE'),
      has_function_privilege('authenticated', 'app_internal.process_job_fanout(timestamptz)', 'EXECUTE'),
      has_function_privilege('service_role', 'app_internal.process_job_fanout(timestamptz)', 'EXECUTE'),
      has_function_privilege('anon', 'app_internal.ru_short_date(date)', 'EXECUTE'),
      has_function_privilege('authenticated', 'app_internal.ru_short_date(date)', 'EXECUTE'),
      has_function_privilege('anon', 'app_internal.shift_start_or_null(jsonb)', 'EXECUTE'),
      has_function_privilege('authenticated', 'app_internal.shift_start_or_null(jsonb)', 'EXECUTE'),
      has_function_privilege('anon', 'app_internal.enqueue_job_fanout()', 'EXECUTE'),
      has_function_privilege('authenticated', 'app_internal.enqueue_job_fanout()', 'EXECUTE'),
      has_function_privilege('service_role', 'app_internal.enqueue_job_fanout()', 'EXECUTE'),
      has_function_privilege('anon', 'public.count_job_audience(uuid)', 'EXECUTE'),
      has_function_privilege('authenticated', 'public.count_job_audience(uuid)', 'EXECUTE'),
      has_function_privilege('service_role', 'public.count_job_audience(uuid)', 'EXECUTE'),
      has_table_privilege('authenticated', 'app_internal.job_fanout_queue', 'SELECT'),
      has_table_privilege('anon', 'app_internal.job_fanout_queue', 'SELECT')
    ]
  ) = ARRAY[false, false, true,  false, false, true,  false, false, true,  false, false,  false, false,
            false, false, true,  false, true, true,  false, false],
    'grants: app_internal for service_role only, count_job_audience for authenticated + service_role, queue table hidden from clients';

  ASSERT (
    SELECT jsonb_build_object('schedule', j.schedule, 'command', j.command)
    FROM cron.job j WHERE j.jobname = 'process_job_fanout'
  ) = jsonb_build_object('schedule', '*/5 * * * *', 'command', 'SELECT app_internal.process_job_fanout();'),
    'cron: process_job_fanout every 5 minutes';

  ASSERT (
    SELECT ARRAY[t.tgtype::TEXT, t.tgenabled::TEXT, (t.tgattr::TEXT <> '')::TEXT]
    FROM pg_trigger t WHERE t.tgrelid = 'public.jobs'::regclass AND t.tgname = 'zz_job_fanout_enqueue'
  ) = ARRAY['21', 'O', 'true'],
    'trigger: AFTER INSERT OR UPDATE OF <column>, FOR EACH ROW, enabled';

  RAISE NOTICE 'ok: grants, cron, trigger definition';
END $$;

ROLLBACK;

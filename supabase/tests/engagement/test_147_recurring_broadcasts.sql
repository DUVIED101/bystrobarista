-- Tests for 147_recurring_broadcasts.sql. Run through run.sh (fixtures +
-- migrations are applied first). One transaction, rolled back at the end.
--
-- Reference moment v_now = today 12:00 MSK (stored in test_ctx) so that the
-- p_now-driven functions and the now()-driven admin RPCs see the same data as
-- "recent" / "stale": every timestamp below is relative to v_now with margins
-- wider than the 12 h gap between v_now and the session clock.
BEGIN;

CREATE TEMP TABLE test_ids (k TEXT PRIMARY KEY, id UUID NOT NULL) ON COMMIT DROP;
CREATE TEMP TABLE test_ctx (k TEXT PRIMARY KEY, ts TIMESTAMPTZ NOT NULL) ON COMMIT DROP;

CREATE FUNCTION pg_temp.tid(p_key TEXT) RETURNS UUID LANGUAGE sql STABLE
AS $$ SELECT id FROM test_ids WHERE k = p_key $$;

CREATE FUNCTION pg_temp.t_now() RETURNS TIMESTAMPTZ LANGUAGE sql STABLE
AS $$ SELECT ts FROM test_ctx WHERE k = 'now' $$;

-- Recipients of a recurring broadcast as [{email, title, body, data}] ordered by email.
CREATE FUNCTION pg_temp.recipients(p_rb UUID, p_now TIMESTAMPTZ) RETURNS JSONB LANGUAGE sql STABLE
AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object('email', u.email, 'title', r.title, 'body', r.body, 'data', r.data)
                            ORDER BY u.email), '[]'::jsonb)
  FROM app_internal.recurring_broadcast_recipients(p_rb, p_now) r
  JOIN public.users u ON u.id = r.user_id
$$;

CREATE FUNCTION pg_temp.exp_row(p_email TEXT, p_title TEXT, p_body TEXT, p_data TEXT) RETURNS JSONB LANGUAGE sql IMMUTABLE
AS $$
  SELECT jsonb_build_object('email', p_email || '@test.local', 'title', p_title, 'body', p_body, 'data', p_data::jsonb)
$$;

CREATE FUNCTION pg_temp.emails_of(p_ids UUID[]) RETURNS TEXT[] LANGUAGE sql STABLE
AS $$ SELECT COALESCE(array_agg(u.email ORDER BY u.email), '{}') FROM public.users u WHERE u.id = ANY (p_ids) $$;

CREATE FUNCTION pg_temp.segment(p_segment JSONB) RETURNS TEXT[] LANGUAGE sql STABLE
AS $$ SELECT pg_temp.emails_of(ARRAY(SELECT r.user_id FROM app_internal.broadcast_segment_recipients(p_segment) r)) $$;

-- ---------------------------------------------------------------------------
-- 1. next_recurring_run (2026-03-10 is a Tuesday)
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_tue_fri INT[] := ARRAY[2, 5];
  v_noon TIME := '12:00';
BEGIN
  ASSERT app_internal.next_recurring_run(v_tue_fri, v_noon, '2026-03-09 10:00+03') = '2026-03-10 12:00+03'::timestamptz,
    'Monday 10:00 -> Tuesday 12:00';
  ASSERT app_internal.next_recurring_run(v_tue_fri, v_noon, '2026-03-10 11:59:59+03') = '2026-03-10 12:00+03'::timestamptz,
    'Tuesday 11:59:59 -> Tuesday 12:00';
  ASSERT app_internal.next_recurring_run(v_tue_fri, v_noon, '2026-03-10 12:00:00+03') = '2026-03-13 12:00+03'::timestamptz,
    'exactly Tuesday 12:00 -> Friday 12:00 (strictly after)';
  ASSERT app_internal.next_recurring_run(v_tue_fri, v_noon, '2026-03-14 09:00+03') = '2026-03-17 12:00+03'::timestamptz,
    'Saturday -> next Tuesday';
  ASSERT app_internal.next_recurring_run(v_tue_fri, v_noon, '2026-03-09 21:30+00') = '2026-03-10 12:00+03'::timestamptz,
    'Monday 21:30 UTC is Tuesday 00:30 MSK -> same Tuesday 12:00';
  ASSERT app_internal.next_recurring_run(ARRAY[2], v_noon, '2026-03-31 13:00+03') = '2026-04-07 12:00+03'::timestamptz,
    'month end: Tuesday 31 Mar 13:00 -> Tuesday 7 Apr';
  ASSERT app_internal.next_recurring_run(ARRAY[1], v_noon, '2026-03-30 23:30+03') = '2026-04-06 12:00+03'::timestamptz,
    'Monday 23:30 -> next Monday';
  ASSERT app_internal.next_recurring_run(ARRAY[7], '09:30', '2026-03-15 13:00+03') = '2026-03-22 09:30+03'::timestamptz,
    'single weekday after its slot -> seven days later';
  ASSERT app_internal.next_recurring_run(NULL, v_noon, '2026-03-10 12:00+03') IS NULL;
  ASSERT app_internal.next_recurring_run(ARRAY[]::INT[], v_noon, '2026-03-10 12:00+03') IS NULL;
  RAISE NOTICE 'ok: next_recurring_run';
END $$;

-- ---------------------------------------------------------------------------
-- 2. Fixture data
-- ---------------------------------------------------------------------------
-- Baristas (spb unless noted; make_user gives completeness 50, looking = true):
--   a {Чернышевская, Площадь Восстания}   b {Площадь Восстания, Адмиралтейская}
--   c {__any__}   d {Невский проспект}   e {}   n {} seen via device token 10 d ago
--   o {Чернышевская} seen 45 d ago (session)   f moscow {}   p moscow {Тверская}
--   excluded: g completeness 29, h seen 61 d ago, i not looking, j banned,
--   k inactive, l admin (first admin, created 2020)
-- Businesses: biz-1 spb (Чернышевская / Площадь Восстания / Адмиралтейская /
--   no station / inactive no station), biz-2 moscow (Тверская), biz-3 spb not
--   accepting (Чернышевская), biz-4 spb (Чернышевская older, Адмиралтейская,
--   inactive no station), biz-5 no branches, biz-6 banned, biz-7 moscow
--   (Арбатская), adm-biz admin (Чернышевская).
DO $$
DECLARE
  v_now TIMESTAMPTZ := ((now() AT TIME ZONE 'Europe/Moscow')::date + TIME '12:00') AT TIME ZONE 'Europe/Moscow';
  v_u UUID;
  v_biz UUID;
  v_br UUID;
  k TEXT;
BEGIN
  INSERT INTO test_ctx VALUES ('now', v_now);
  UPDATE public.feature_flags SET value = '"on"' WHERE key = 'engagement_push_mode';

  FOREACH k IN ARRAY ARRAY['a', 'b', 'c', 'd', 'e', 'n', 'o', 'f', 'p', 'g', 'h', 'i', 'j', 'k'] LOOP
    v_u := test.make_user('bar-' || k || '@test.local', 'barista');
    INSERT INTO test_ids VALUES ('bar_' || k, v_u);
  END LOOP;
  v_u := test.make_user('bar-l@test.local', 'barista', true, '2020-01-01 00:00+03');
  INSERT INTO test_ids VALUES ('bar_l', v_u);

  UPDATE public.barista_profiles SET preferred_metro_stations = '{Чернышевская,"Площадь Восстания"}' WHERE user_id = pg_temp.tid('bar_a');
  UPDATE public.barista_profiles SET preferred_metro_stations = '{"Площадь Восстания",Адмиралтейская}' WHERE user_id = pg_temp.tid('bar_b');
  UPDATE public.barista_profiles SET preferred_metro_stations = '{__any__}' WHERE user_id = pg_temp.tid('bar_c');
  UPDATE public.barista_profiles SET preferred_metro_stations = '{"Невский проспект"}' WHERE user_id = pg_temp.tid('bar_d');
  UPDATE public.barista_profiles SET preferred_metro_stations = '{Чернышевская}' WHERE user_id = pg_temp.tid('bar_o');
  UPDATE public.barista_profiles SET city = 'moscow' WHERE user_id IN (pg_temp.tid('bar_f'), pg_temp.tid('bar_p'));
  UPDATE public.barista_profiles SET preferred_metro_stations = '{Тверская}' WHERE user_id = pg_temp.tid('bar_p');
  UPDATE public.barista_profiles SET profile_completeness = 29, preferred_metro_stations = '{Чернышевская}' WHERE user_id = pg_temp.tid('bar_g');
  UPDATE public.barista_profiles SET is_actively_looking = false WHERE user_id = pg_temp.tid('bar_i');
  UPDATE public.barista_profiles SET preferred_metro_stations = '{Чернышевская}' WHERE user_id = pg_temp.tid('bar_l');
  UPDATE public.users SET banned_at = v_now - INTERVAL '1 day' WHERE id = pg_temp.tid('bar_j');
  UPDATE public.users SET is_active = false WHERE id = pg_temp.tid('bar_k');

  INSERT INTO public.user_activity (user_id, last_seen_at)
  SELECT pg_temp.tid('bar_' || x), v_now - INTERVAL '1 day'
  FROM unnest(ARRAY['a', 'b', 'c', 'd', 'e', 'f', 'p', 'g', 'i', 'j', 'k', 'l']) AS x;
  INSERT INTO public.user_activity (user_id, last_seen_at) VALUES (pg_temp.tid('bar_h'), v_now - INTERVAL '61 days');
  INSERT INTO public.device_tokens (user_id, device_token, environment, last_seen_at)
  VALUES (pg_temp.tid('bar_n'), 'tok-n', 'production', v_now - INTERVAL '10 days');
  INSERT INTO auth.sessions (user_id, refreshed_at)
  VALUES (pg_temp.tid('bar_o'), (v_now - INTERVAL '45 days') AT TIME ZONE 'UTC');

  FOREACH k IN ARRAY ARRAY['1', '2', '3', '4', '5', '6', '7'] LOOP
    v_u := test.make_user('biz-' || k || '@test.local', 'business');
    INSERT INTO test_ids VALUES ('biz_' || k, v_u);
    INSERT INTO public.user_activity (user_id, last_seen_at) VALUES (v_u, v_now - INTERVAL '1 day');
  END LOOP;
  v_u := test.make_user('adm-biz@test.local', 'business', true, '2021-01-01 00:00+03');
  INSERT INTO test_ids VALUES ('adm_biz', v_u);

  UPDATE public.businesses SET is_accepting_applications = false WHERE owner_id = pg_temp.tid('biz_3');
  UPDATE public.users SET banned_at = v_now - INTERVAL '2 days' WHERE id = pg_temp.tid('biz_6');

  -- biz-1 branches
  SELECT id INTO v_biz FROM public.businesses WHERE owner_id = pg_temp.tid('biz_1');
  INSERT INTO public.branches (business_id, name, city, metro_station, is_active, created_at)
  VALUES (v_biz, 'Чернышевская точка', 'spb', 'Чернышевская', true, v_now - INTERVAL '10 days') RETURNING id INTO v_br;
  INSERT INTO test_ids VALUES ('br_cher', v_br);
  INSERT INTO public.branches (business_id, name, city, metro_station, is_active, created_at)
  VALUES (v_biz, 'Площадь', 'spb', 'Площадь Восстания', true, v_now - INTERVAL '9 days') RETURNING id INTO v_br;
  INSERT INTO test_ids VALUES ('br_plo', v_br);
  INSERT INTO public.branches (business_id, name, city, metro_station, is_active, created_at)
  VALUES (v_biz, 'Адмиралтейская точка', 'spb', 'Адмиралтейская', true, v_now - INTERVAL '8 days') RETURNING id INTO v_br;
  INSERT INTO test_ids VALUES ('br_adm', v_br);
  INSERT INTO public.branches (business_id, name, city, metro_station, is_active, created_at)
  VALUES (v_biz, 'Без станции', 'spb', NULL, true, v_now - INTERVAL '7 days') RETURNING id INTO v_br;
  INSERT INTO test_ids VALUES ('br_none', v_br);
  INSERT INTO public.branches (business_id, name, city, metro_station, is_active, created_at)
  VALUES (v_biz, 'Закрытая', 'spb', NULL, false, v_now - INTERVAL '20 days') RETURNING id INTO v_br;
  INSERT INTO test_ids VALUES ('br_inactive', v_br);

  -- biz-1 jobs (compensation matters only for admin_social_digest)
  INSERT INTO public.jobs (business_id, business_owner_id, branch_id, status, posted_at, compensation) VALUES
    (v_biz, pg_temp.tid('biz_1'), pg_temp.tid('br_cher'), 'open', v_now - INTERVAL '1 day', '{"type":"hourly","amount":500,"currency":"RUB"}'),
    (v_biz, pg_temp.tid('biz_1'), pg_temp.tid('br_cher'), 'open', v_now - INTERVAL '2 days', '{"type":"hourly","amount":"650","currency":"RUB"}'),
    (v_biz, pg_temp.tid('biz_1'), pg_temp.tid('br_plo'), 'open', v_now - INTERVAL '1 day', '{"type":"daily","amount":5000,"currency":"RUB"}'),
    (v_biz, pg_temp.tid('biz_1'), pg_temp.tid('br_adm'), 'open', v_now - INTERVAL '1 day', '{"type":"fixed","amount":3000,"currency":"RUB"}'),
    (v_biz, pg_temp.tid('biz_1'), pg_temp.tid('br_cher'), 'open', v_now - INTERVAL '4 days', '{"type":"hourly","amount":400,"currency":"RUB"}'),
    (v_biz, pg_temp.tid('biz_1'), pg_temp.tid('br_cher'), 'filled', v_now - INTERVAL '1 day', '{"type":"hourly","amount":100,"currency":"RUB"}'),
    (v_biz, pg_temp.tid('biz_1'), pg_temp.tid('br_inactive'), 'open', v_now - INTERVAL '1 day', '{"type":"hourly","amount":50,"currency":"RUB"}');
  -- posted_at NULL falls back to created_at
  INSERT INTO public.jobs (business_id, business_owner_id, branch_id, status, posted_at, created_at, compensation)
  VALUES (v_biz, pg_temp.tid('biz_1'), pg_temp.tid('br_none'), 'open', NULL, v_now - INTERVAL '2 days', '{"type":"hourly","amount":450,"currency":"RUB"}');

  -- biz-2 moscow, one job outside the 3-day lookback for now
  SELECT id INTO v_biz FROM public.businesses WHERE owner_id = pg_temp.tid('biz_2');
  INSERT INTO public.branches (business_id, name, city, metro_station, is_active, created_at)
  VALUES (v_biz, 'Тверская точка', 'moscow', 'Тверская', true, v_now - INTERVAL '5 days') RETURNING id INTO v_br;
  INSERT INTO test_ids VALUES ('br_tver', v_br);
  INSERT INTO public.jobs (business_id, business_owner_id, branch_id, status, posted_at, compensation)
  VALUES (v_biz, pg_temp.tid('biz_2'), v_br, 'open', v_now - INTERVAL '4 days', '{"type":"hourly","amount":700,"currency":"RUB"}')
  RETURNING id INTO v_u;
  INSERT INTO test_ids VALUES ('job_msk', v_u);

  -- biz-3 not accepting applications
  SELECT id INTO v_biz FROM public.businesses WHERE owner_id = pg_temp.tid('biz_3');
  INSERT INTO public.branches (business_id, name, city, metro_station, is_active, created_at)
  VALUES (v_biz, 'Третья', 'spb', 'Чернышевская', true, v_now - INTERVAL '5 days') RETURNING id INTO v_br;
  INSERT INTO test_ids VALUES ('br_3', v_br);
  INSERT INTO public.jobs (business_id, business_owner_id, branch_id, status, posted_at, compensation)
  VALUES (v_biz, pg_temp.tid('biz_3'), v_br, 'open', v_now - INTERVAL '1 day', '{"type":"hourly","amount":10,"currency":"RUB"}');

  -- biz-4: tie between two station branches, older wins; inactive branch ignored
  SELECT id INTO v_biz FROM public.businesses WHERE owner_id = pg_temp.tid('biz_4');
  INSERT INTO public.branches (business_id, name, city, metro_station, is_active, created_at)
  VALUES (v_biz, 'Четвёртая А', 'spb', 'Чернышевская', true, v_now - INTERVAL '6 days') RETURNING id INTO v_br;
  INSERT INTO test_ids VALUES ('br_4a', v_br);
  INSERT INTO public.branches (business_id, name, city, metro_station, is_active, created_at)
  VALUES (v_biz, 'Четвёртая Б', 'spb', 'Адмиралтейская', true, v_now - INTERVAL '5 days') RETURNING id INTO v_br;
  INSERT INTO test_ids VALUES ('br_4b', v_br);
  INSERT INTO public.branches (business_id, name, city, metro_station, is_active, created_at)
  VALUES (v_biz, 'Четвёртая закрытая', 'spb', NULL, false, v_now - INTERVAL '30 days');

  -- biz-6 banned owner
  SELECT id INTO v_biz FROM public.businesses WHERE owner_id = pg_temp.tid('biz_6');
  INSERT INTO public.branches (business_id, name, city, metro_station, is_active) VALUES (v_biz, 'Бан', 'spb', 'Чернышевская', true);

  -- biz-7 moscow, station nobody prefers
  SELECT id INTO v_biz FROM public.businesses WHERE owner_id = pg_temp.tid('biz_7');
  INSERT INTO public.branches (business_id, name, city, metro_station, is_active) VALUES (v_biz, 'Арбат', 'moscow', 'Арбатская', true);

  -- admin-owned business: neither source nor recipient
  SELECT id INTO v_biz FROM public.businesses WHERE owner_id = pg_temp.tid('adm_biz');
  INSERT INTO public.branches (business_id, name, city, metro_station, is_active) VALUES (v_biz, 'Админ', 'spb', 'Чернышевская', true) RETURNING id INTO v_br;
  INSERT INTO public.jobs (business_id, business_owner_id, branch_id, status, posted_at, compensation)
  VALUES (v_biz, pg_temp.tid('adm_biz'), v_br, 'open', v_now - INTERVAL '1 day', '{"type":"hourly","amount":999,"currency":"RUB"}');

  SELECT id INTO v_u FROM public.recurring_broadcasts WHERE name = 'Смены у метро — вт/пт';
  INSERT INTO test_ids VALUES ('rb_jobs', v_u);
  SELECT id INTO v_u FROM public.recurring_broadcasts WHERE name = 'Бариста рядом — вт/пт';
  INSERT INTO test_ids VALUES ('rb_near', v_u);

  -- Variants of the seeded templates (inactive, used only through recipients())
  INSERT INTO public.recurring_broadcasts (name, template, city, weekdays, send_time, lookback_days, min_count, title, body, body_city)
  SELECT 'jobs spb', 'new_jobs_near_metro', 'spb', ARRAY[2, 5], '12:00', 3, 1, rb.title, rb.body, rb.body_city
  FROM public.recurring_broadcasts rb WHERE rb.id = pg_temp.tid('rb_jobs') RETURNING id INTO v_u;
  INSERT INTO test_ids VALUES ('rb_jobs_spb', v_u);
  INSERT INTO public.recurring_broadcasts (name, template, city, weekdays, send_time, lookback_days, min_count, title, body, body_city)
  SELECT 'jobs moscow', 'new_jobs_near_metro', 'moscow', ARRAY[2, 5], '12:00', 3, 1, rb.title, rb.body, rb.body_city
  FROM public.recurring_broadcasts rb WHERE rb.id = pg_temp.tid('rb_jobs') RETURNING id INTO v_u;
  INSERT INTO test_ids VALUES ('rb_jobs_msk', v_u);
  INSERT INTO public.recurring_broadcasts (name, template, city, weekdays, send_time, lookback_days, min_count, title, body, body_city)
  SELECT 'jobs min 3', 'new_jobs_near_metro', NULL, ARRAY[2, 5], '12:00', 3, 3, rb.title, rb.body, rb.body_city
  FROM public.recurring_broadcasts rb WHERE rb.id = pg_temp.tid('rb_jobs') RETURNING id INTO v_u;
  INSERT INTO test_ids VALUES ('rb_jobs_min3', v_u);
  INSERT INTO public.recurring_broadcasts (name, template, city, weekdays, send_time, lookback_days, min_count, title, body, body_city)
  SELECT 'near spb', 'baristas_nearby', 'spb', ARRAY[2, 5], '12:00', 3, 1, rb.title, rb.body, rb.body_city
  FROM public.recurring_broadcasts rb WHERE rb.id = pg_temp.tid('rb_near') RETURNING id INTO v_u;
  INSERT INTO test_ids VALUES ('rb_near_spb', v_u);
  INSERT INTO public.recurring_broadcasts (name, template, city, weekdays, send_time, lookback_days, min_count, title, body, body_city)
  SELECT 'near min 3', 'baristas_nearby', NULL, ARRAY[2, 5], '12:00', 3, 3, rb.title, rb.body, rb.body_city
  FROM public.recurring_broadcasts rb WHERE rb.id = pg_temp.tid('rb_near') RETURNING id INTO v_u;
  INSERT INTO test_ids VALUES ('rb_near_min3', v_u);

  RAISE NOTICE 'ok: fixtures (v_now = %)', v_now;
END $$;

-- ---------------------------------------------------------------------------
-- 3. recipients: new_jobs_near_metro
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_now TIMESTAMPTZ := pg_temp.t_now();
  v_rb TEXT := pg_temp.tid('rb_jobs')::TEXT;
  v_title TEXT := 'Новые смены рядом';
  v_spb5 TEXT := '5 новых смен в Петербурге';
  v_data_spb TEXT := format('{"kind":"recurring_broadcast","city":"spb","recurringBroadcastId":"%s"}', v_rb);
  v_data_cher TEXT := format('{"kind":"recurring_broadcast","city":"spb","metroStation":"Чернышевская","recurringBroadcastId":"%s"}', v_rb);
  v_data_adm TEXT := format('{"kind":"recurring_broadcast","city":"spb","metroStation":"Адмиралтейская","recurringBroadcastId":"%s"}', v_rb);
  v_actual JSONB;
BEGIN
  v_actual := pg_temp.recipients(pg_temp.tid('rb_jobs'), v_now);
  ASSERT v_actual = jsonb_build_array(
    pg_temp.exp_row('bar-a', v_title, '3 новые смены у м. Чернышевская', v_data_cher),
    pg_temp.exp_row('bar-b', v_title, '2 новые смены у м. Адмиралтейская', v_data_adm),
    pg_temp.exp_row('bar-c', v_title, v_spb5, v_data_spb),
    pg_temp.exp_row('bar-d', v_title, v_spb5, v_data_spb),
    pg_temp.exp_row('bar-e', v_title, v_spb5, v_data_spb),
    pg_temp.exp_row('bar-n', v_title, v_spb5, v_data_spb),
    pg_temp.exp_row('bar-o', v_title, '2 новые смены у м. Чернышевская', v_data_cher)
  ), format('new_jobs_near_metro, no recent moscow jobs: %s', jsonb_pretty(v_actual));

  -- The moscow job becomes recent: f gets the city text, p the station text.
  UPDATE public.jobs SET posted_at = v_now - INTERVAL '1 day' WHERE id = pg_temp.tid('job_msk');
  v_actual := pg_temp.recipients(pg_temp.tid('rb_jobs'), v_now);
  ASSERT v_actual = jsonb_build_array(
    pg_temp.exp_row('bar-a', v_title, '3 новые смены у м. Чернышевская', v_data_cher),
    pg_temp.exp_row('bar-b', v_title, '2 новые смены у м. Адмиралтейская', v_data_adm),
    pg_temp.exp_row('bar-c', v_title, v_spb5, v_data_spb),
    pg_temp.exp_row('bar-d', v_title, v_spb5, v_data_spb),
    pg_temp.exp_row('bar-e', v_title, v_spb5, v_data_spb),
    pg_temp.exp_row('bar-f', v_title, '1 новая смена в Москве',
      format('{"kind":"recurring_broadcast","city":"moscow","recurringBroadcastId":"%s"}', v_rb)),
    pg_temp.exp_row('bar-n', v_title, v_spb5, v_data_spb),
    pg_temp.exp_row('bar-o', v_title, '2 новые смены у м. Чернышевская', v_data_cher),
    pg_temp.exp_row('bar-p', v_title, '1 новая смена у м. Тверская',
      format('{"kind":"recurring_broadcast","city":"moscow","metroStation":"Тверская","recurringBroadcastId":"%s"}', v_rb))
  ), format('new_jobs_near_metro with a recent moscow job: %s', jsonb_pretty(v_actual));

  ASSERT (SELECT array_agg(x->>'email' ORDER BY x->>'email') FROM jsonb_array_elements(pg_temp.recipients(pg_temp.tid('rb_jobs_spb'), v_now)) x)
    = ARRAY['bar-a@test.local', 'bar-b@test.local', 'bar-c@test.local', 'bar-d@test.local', 'bar-e@test.local', 'bar-n@test.local', 'bar-o@test.local'],
    'rb.city = spb keeps only spb baristas';
  ASSERT (SELECT array_agg(x->>'email' ORDER BY x->>'email') FROM jsonb_array_elements(pg_temp.recipients(pg_temp.tid('rb_jobs_msk'), v_now)) x)
    = ARRAY['bar-f@test.local', 'bar-p@test.local'],
    'rb.city = moscow keeps only moscow baristas';
  ASSERT (SELECT jsonb_agg(jsonb_build_object('email', x->>'email', 'body', x->>'body') ORDER BY x->>'email')
          FROM jsonb_array_elements(pg_temp.recipients(pg_temp.tid('rb_jobs_min3'), v_now)) x)
    = jsonb_build_array(
        jsonb_build_object('email', 'bar-a@test.local', 'body', '3 новые смены у м. Чернышевская'),
        jsonb_build_object('email', 'bar-b@test.local', 'body', v_spb5),
        jsonb_build_object('email', 'bar-c@test.local', 'body', v_spb5),
        jsonb_build_object('email', 'bar-d@test.local', 'body', v_spb5),
        jsonb_build_object('email', 'bar-e@test.local', 'body', v_spb5),
        jsonb_build_object('email', 'bar-n@test.local', 'body', v_spb5),
        jsonb_build_object('email', 'bar-o@test.local', 'body', v_spb5)),
    'min_count = 3: station counts below it fall back to the city text, the 1-shift moscow messages are dropped';

  RAISE NOTICE 'ok: recipients new_jobs_near_metro';
END $$;

-- ---------------------------------------------------------------------------
-- 4. recipients: baristas_nearby
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_now TIMESTAMPTZ := pg_temp.t_now();
  v_rb TEXT := pg_temp.tid('rb_near')::TEXT;
  v_title TEXT := 'Бариста рядом с вашей точкой';
  v_actual JSONB;
BEGIN
  v_actual := pg_temp.recipients(pg_temp.tid('rb_near'), v_now);
  ASSERT v_actual = jsonb_build_array(
    pg_temp.exp_row('biz-1', v_title, 'Ищут смены в Петербурге: 6 бариста',
      format('{"kind":"recurring_broadcast","city":"spb","branchId":"%s","recurringBroadcastId":"%s"}', pg_temp.tid('br_none'), v_rb)),
    pg_temp.exp_row('biz-2', v_title, 'Ищут смены у м. Тверская: 1 бариста',
      format('{"kind":"recurring_broadcast","city":"moscow","metroStation":"Тверская","branchId":"%s","recurringBroadcastId":"%s"}', pg_temp.tid('br_tver'), v_rb)),
    pg_temp.exp_row('biz-3', v_title, 'Ищут смены у м. Чернышевская: 2 бариста',
      format('{"kind":"recurring_broadcast","city":"spb","metroStation":"Чернышевская","branchId":"%s","recurringBroadcastId":"%s"}', pg_temp.tid('br_3'), v_rb)),
    pg_temp.exp_row('biz-4', v_title, 'Ищут смены у м. Чернышевская: 2 бариста',
      format('{"kind":"recurring_broadcast","city":"spb","metroStation":"Чернышевская","branchId":"%s","recurringBroadcastId":"%s"}', pg_temp.tid('br_4a'), v_rb))
  ), format('baristas_nearby: %s', jsonb_pretty(v_actual));

  ASSERT (SELECT array_agg(x->>'email' ORDER BY x->>'email') FROM jsonb_array_elements(pg_temp.recipients(pg_temp.tid('rb_near_spb'), v_now)) x)
    = ARRAY['biz-1@test.local', 'biz-3@test.local', 'biz-4@test.local'],
    'rb.city = spb keeps only owners with spb branches';
  ASSERT (SELECT array_agg(x->>'email' ORDER BY x->>'email') FROM jsonb_array_elements(pg_temp.recipients(pg_temp.tid('rb_near_min3'), v_now)) x)
    = ARRAY['biz-1@test.local'],
    'min_count = 3 keeps only the 6-barista message';

  RAISE NOTICE 'ok: recipients baristas_nearby';
END $$;

-- ---------------------------------------------------------------------------
-- 5. run_recurring_broadcast
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_now TIMESTAMPTZ := pg_temp.t_now();
  v_msk_date DATE := (v_now AT TIME ZONE 'Europe/Moscow')::date;
  v_dow_tomorrow INT := EXTRACT(ISODOW FROM v_msk_date + 1)::INT;
  v_expected_next TIMESTAMPTZ := (v_msk_date + 1 + TIME '12:00') AT TIME ZONE 'Europe/Moscow';
  v_rb UUID;
  v_n INT;
  v_broadcast RECORD;
  v_run RECORD;
  v_expected_keys TEXT[];
BEGIN
  INSERT INTO public.recurring_broadcasts (name, template, city, weekdays, send_time, lookback_days, min_count, title, body, body_city, is_active, next_run_at)
  VALUES ('run me', 'new_jobs_near_metro', NULL, ARRAY[v_dow_tomorrow], '12:00', 3, 1,
          'Новые смены рядом', '{count} {shifts} у м. {metro}', '{count} {shifts} в {city}', true, v_now)
  RETURNING id INTO v_rb;
  INSERT INTO test_ids VALUES ('rb_run', v_rb);

  v_n := app_internal.run_recurring_broadcast(v_rb, 'cron', NULL, v_now);
  ASSERT v_n = 9, format('first run returns 9 recipients, got %s', v_n);

  SELECT * INTO v_broadcast FROM public.broadcasts b WHERE b.segment->>'recurring_broadcast_id' = v_rb::TEXT;
  ASSERT v_broadcast.segment = jsonb_build_object('recurring_broadcast_id', v_rb, 'template', 'new_jobs_near_metro', 'city', NULL)
     AND v_broadcast.title = 'Новые смены рядом'
     AND v_broadcast.body = '{count} {shifts} у м. {metro}'
     AND v_broadcast.channel = ARRAY['push']
     AND v_broadcast.scheduled_for IS NULL
     AND v_broadcast.sent_at = v_now
     AND v_broadcast.delivered_count = 9
     AND v_broadcast.created_by = pg_temp.tid('bar_l'),
    format('broadcasts history row (created_by falls back to the first admin): %s', to_jsonb(v_broadcast));

  SELECT * INTO v_run FROM public.recurring_broadcast_runs r WHERE r.recurring_broadcast_id = v_rb;
  ASSERT (v_run.broadcast_id, v_run.ran_at, v_run.recipient_count, v_run.trigger, v_run.admin_id, v_run.queued_count, v_run.push_mode)
       IS NOT DISTINCT FROM (v_broadcast.id, v_now, 9, 'cron', NULL::UUID, 9, 'on'),
    format('runs row: %s', to_jsonb(v_run));

  SELECT array_agg(format('rb:%s:%s:%s', v_rb, v_msk_date, pg_temp.tid('bar_' || x)) ORDER BY 1)
    INTO v_expected_keys
  FROM unnest(ARRAY['a', 'b', 'c', 'd', 'e', 'f', 'n', 'o', 'p']) AS x;
  ASSERT (SELECT array_agg(ep.dedupe_key ORDER BY ep.dedupe_key) FROM app_internal.engagement_pushes ep
          WHERE ep.kind = 'recurring_broadcast' AND ep.data->>'recurringBroadcastId' = v_rb::TEXT)
       = (SELECT array_agg(k ORDER BY k) FROM unnest(v_expected_keys) k),
    'one queued push per recipient with dedupe_key rb:<id>:<msk date>:<user>';
  ASSERT (SELECT jsonb_agg(jsonb_build_object('title', ep.title, 'body', ep.body, 'data', ep.data, 'send_after', ep.send_after, 'sent_at', ep.sent_at))
          FROM app_internal.engagement_pushes ep
          WHERE ep.user_id = pg_temp.tid('bar_a') AND ep.data->>'recurringBroadcastId' = v_rb::TEXT)
       = jsonb_build_array(jsonb_build_object(
           'title', 'Новые смены рядом',
           'body', '3 новые смены у м. Чернышевская',
           'data', format('{"kind":"recurring_broadcast","city":"spb","metroStation":"Чернышевская","recurringBroadcastId":"%s"}', v_rb)::jsonb,
           'send_after', v_now,
           'sent_at', NULL)),
    'queued push carries the rendered text and string-only data';
  ASSERT (SELECT ARRAY[rb.last_run_at, rb.next_run_at] FROM public.recurring_broadcasts rb WHERE rb.id = v_rb)
       = ARRAY[v_now, v_expected_next],
    'last_run_at = p_now, next_run_at = tomorrow 12:00 MSK';

  -- Second run the same day: dedupe keeps the queue at 9, history grows.
  v_n := app_internal.run_recurring_broadcast(v_rb, 'manual', pg_temp.tid('adm_biz'), v_now + INTERVAL '1 hour');
  ASSERT v_n = 9, 'second run still counts 9 recipients';
  ASSERT (SELECT count(*) FROM app_internal.engagement_pushes ep WHERE ep.data->>'recurringBroadcastId' = v_rb::TEXT) = 9,
    'no duplicate pushes on the same Moscow day';
  ASSERT (SELECT array_agg(ROW(r.trigger, r.admin_id, r.ran_at, r.recipient_count, r.queued_count)::TEXT ORDER BY r.ran_at)
          FROM public.recurring_broadcast_runs r WHERE r.recurring_broadcast_id = v_rb)
       = ARRAY[ROW('cron', NULL::UUID, v_now, 9, 9)::TEXT, ROW('manual', pg_temp.tid('adm_biz'), v_now + INTERVAL '1 hour', 9, 0)::TEXT],
    'every run gets its own runs row; the deduped second run queued nothing';
  ASSERT (SELECT array_agg(ROW(b.created_by, b.delivered_count)::TEXT ORDER BY b.sent_at) FROM public.broadcasts b WHERE b.segment->>'recurring_broadcast_id' = v_rb::TEXT)
       = ARRAY[ROW(pg_temp.tid('bar_l'), 9)::TEXT, ROW(pg_temp.tid('adm_biz'), 0)::TEXT],
    'manual run attributes the broadcasts row to the acting admin; delivered_count = pushes actually queued';
  ASSERT (SELECT ARRAY[rb.last_run_at, rb.next_run_at] FROM public.recurring_broadcasts rb WHERE rb.id = v_rb)
       = ARRAY[v_now + INTERVAL '1 hour', v_expected_next];

  -- Zero recipients: runs row only, schedule still advances.
  INSERT INTO public.recurring_broadcasts (name, template, city, weekdays, send_time, lookback_days, min_count, title, body, body_city, is_active, next_run_at)
  VALUES ('zero', 'baristas_nearby', 'moscow', ARRAY[v_dow_tomorrow], '12:00', 3, 5, 't', 'b', 'bc', true, v_now)
  RETURNING id INTO v_rb;
  INSERT INTO test_ids VALUES ('rb_zero', v_rb);
  ASSERT app_internal.run_recurring_broadcast(v_rb, 'cron', NULL, v_now) = 0;
  ASSERT (SELECT count(*) FROM public.broadcasts b WHERE b.segment->>'recurring_broadcast_id' = v_rb::TEXT) = 0, 'no broadcasts row for an empty run';
  ASSERT (SELECT array_agg(ROW(r.broadcast_id, r.recipient_count, r.queued_count, r.push_mode, r.trigger)::TEXT) FROM public.recurring_broadcast_runs r WHERE r.recurring_broadcast_id = v_rb)
       = ARRAY[ROW(NULL::UUID, 0, 0, 'on', 'cron')::TEXT], 'empty run is still journaled';
  ASSERT (SELECT rb.next_run_at FROM public.recurring_broadcasts rb WHERE rb.id = v_rb) = v_expected_next;

  RAISE NOTICE 'ok: run_recurring_broadcast (history, queue, dedupe, schedule)';
END $$;

-- One failing recipient must not abort the run.
CREATE FUNCTION test.fail_push_for_user()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.user_id::TEXT = current_setting('test.fail_user', true) THEN
    RAISE EXCEPTION 'simulated enqueue failure';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER test_fail_push BEFORE INSERT ON app_internal.engagement_pushes
  FOR EACH ROW EXECUTE FUNCTION test.fail_push_for_user();

DO $$
DECLARE
  v_now TIMESTAMPTZ := pg_temp.t_now();
  v_dow_tomorrow INT := EXTRACT(ISODOW FROM (v_now AT TIME ZONE 'Europe/Moscow')::date + 1)::INT;
  v_rb UUID;
BEGIN
  INSERT INTO public.recurring_broadcasts (name, template, city, weekdays, send_time, lookback_days, min_count, title, body, body_city, is_active, next_run_at)
  VALUES ('fail one', 'new_jobs_near_metro', 'spb', ARRAY[v_dow_tomorrow], '12:00', 3, 1, 't', '{count} {metro}', '{count} {city}', true, v_now)
  RETURNING id INTO v_rb;
  INSERT INTO test_ids VALUES ('rb_fail', v_rb);
  PERFORM set_config('test.fail_user', pg_temp.tid('bar_c')::TEXT, true);

  ASSERT app_internal.run_recurring_broadcast(v_rb, 'cron', NULL, v_now) = 7, 'all 7 recipients are counted';
  ASSERT (SELECT count(*) FROM app_internal.engagement_pushes ep WHERE ep.data->>'recurringBroadcastId' = v_rb::TEXT) = 6,
    'the failing recipient is skipped, the other 6 are queued';
  ASSERT (SELECT b.delivered_count FROM public.broadcasts b WHERE b.segment->>'recurring_broadcast_id' = v_rb::TEXT) = 6,
    'delivered_count counts queued pushes, not the audience';
  ASSERT (SELECT ROW(r.recipient_count, r.queued_count, r.push_mode)::TEXT FROM public.recurring_broadcast_runs r WHERE r.recurring_broadcast_id = v_rb)
       = ROW(7, 6, 'on')::TEXT, 'runs row: audience 7, queued 6';

  PERFORM set_config('test.fail_user', '', true);
  RAISE NOTICE 'ok: a throwing enqueue is isolated per recipient';
END $$;

DROP TRIGGER test_fail_push ON app_internal.engagement_pushes;
DROP FUNCTION test.fail_push_for_user();

-- No admin user at all: broadcasts row skipped, run still journaled.
DO $$
DECLARE
  v_now TIMESTAMPTZ := pg_temp.t_now();
  v_dow_tomorrow INT := EXTRACT(ISODOW FROM (v_now AT TIME ZONE 'Europe/Moscow')::date + 1)::INT;
  v_rb UUID;
BEGIN
  INSERT INTO public.recurring_broadcasts (name, template, city, weekdays, send_time, lookback_days, min_count, title, body, body_city, is_active, next_run_at)
  VALUES ('near moscow', 'baristas_nearby', 'moscow', ARRAY[v_dow_tomorrow], '12:00', 3, 1, 't', 'b', 'bc', true, v_now)
  RETURNING id INTO v_rb;
  INSERT INTO test_ids VALUES ('rb_near_msk', v_rb);

  UPDATE public.users SET is_admin = false WHERE id IN (pg_temp.tid('bar_l'), pg_temp.tid('adm_biz'));
  ASSERT app_internal.run_recurring_broadcast(v_rb, 'cron', NULL, v_now) = 1, 'biz-2 is the only moscow recipient';
  ASSERT (SELECT count(*) FROM public.broadcasts b WHERE b.segment->>'recurring_broadcast_id' = v_rb::TEXT) = 0,
    'no admin to own the broadcasts row -> skipped';
  ASSERT (SELECT array_agg(ROW(r.broadcast_id, r.recipient_count)::TEXT) FROM public.recurring_broadcast_runs r WHERE r.recurring_broadcast_id = v_rb)
       = ARRAY[ROW(NULL::UUID, 1)::TEXT];
  ASSERT (SELECT count(*) FROM app_internal.engagement_pushes ep WHERE ep.user_id = pg_temp.tid('biz_2') AND ep.data->>'recurringBroadcastId' = v_rb::TEXT) = 1;
  UPDATE public.users SET is_admin = true WHERE id IN (pg_temp.tid('bar_l'), pg_temp.tid('adm_biz'));
  RAISE NOTICE 'ok: run without any admin user';
END $$;

-- Modes off / dry_run: the history must not claim deliveries that never queued.
DO $$
DECLARE
  v_now TIMESTAMPTZ := pg_temp.t_now();
  v_dow_tomorrow INT := EXTRACT(ISODOW FROM (v_now AT TIME ZONE 'Europe/Moscow')::date + 1)::INT;
  v_rb_off UUID;
  v_rb_dry UUID;
BEGIN
  INSERT INTO public.recurring_broadcasts (name, template, city, weekdays, send_time, lookback_days, min_count, title, body, body_city, is_active, next_run_at)
  VALUES ('mode off', 'new_jobs_near_metro', 'moscow', ARRAY[v_dow_tomorrow], '12:00', 3, 1, 't', '{count} {metro}', '{count} {city}', true, v_now)
  RETURNING id INTO v_rb_off;
  INSERT INTO public.recurring_broadcasts (name, template, city, weekdays, send_time, lookback_days, min_count, title, body, body_city, is_active, next_run_at)
  VALUES ('mode dry_run', 'new_jobs_near_metro', 'moscow', ARRAY[v_dow_tomorrow], '12:00', 3, 1, 't', '{count} {metro}', '{count} {city}', true, v_now)
  RETURNING id INTO v_rb_dry;

  UPDATE public.feature_flags SET value = '"off"' WHERE key = 'engagement_push_mode';
  ASSERT app_internal.run_recurring_broadcast(v_rb_off, 'cron', NULL, v_now) = 2, 'audience (f, p) is still reported in mode off';
  ASSERT (SELECT ROW(r.recipient_count, r.queued_count, r.push_mode, r.broadcast_id IS NOT NULL)::TEXT
          FROM public.recurring_broadcast_runs r WHERE r.recurring_broadcast_id = v_rb_off)
       = ROW(2, 0, 'off', true)::TEXT, 'mode off: nothing queued, run journaled with push_mode off';
  ASSERT (SELECT b.delivered_count FROM public.broadcasts b WHERE b.segment->>'recurring_broadcast_id' = v_rb_off::TEXT) = 0,
    'mode off: history row says delivered 0';
  ASSERT (SELECT count(*) FROM app_internal.engagement_pushes ep WHERE ep.data->>'recurringBroadcastId' = v_rb_off::TEXT) = 0;

  -- dry_run still queues (143: rows are resolved later with skipped_reason = dry_run).
  UPDATE public.feature_flags SET value = '"dry_run"' WHERE key = 'engagement_push_mode';
  ASSERT app_internal.run_recurring_broadcast(v_rb_dry, 'cron', NULL, v_now) = 2;
  ASSERT (SELECT ROW(r.recipient_count, r.queued_count, r.push_mode)::TEXT
          FROM public.recurring_broadcast_runs r WHERE r.recurring_broadcast_id = v_rb_dry)
       = ROW(2, 2, 'dry_run')::TEXT, 'dry_run: pushes queued, mode recorded';
  ASSERT (SELECT b.delivered_count FROM public.broadcasts b WHERE b.segment->>'recurring_broadcast_id' = v_rb_dry::TEXT) = 2;
  ASSERT (SELECT count(*) FROM app_internal.engagement_pushes ep
          WHERE ep.data->>'recurringBroadcastId' = v_rb_dry::TEXT AND ep.sent_at IS NULL AND ep.skipped_reason IS NULL) = 2,
    'dry_run rows wait in the queue for process_engagement_pushes';

  UPDATE public.feature_flags SET value = '"on"' WHERE key = 'engagement_push_mode';
  RAISE NOTICE 'ok: queued_count / push_mode in modes off and dry_run';
END $$;

-- ---------------------------------------------------------------------------
-- 6. process_recurring_broadcasts
-- ---------------------------------------------------------------------------
-- A run that throws must consume its slot (no 15-minute retry loop).
CREATE FUNCTION test.fail_run_for_rb()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.recurring_broadcast_id::TEXT = current_setting('test.fail_rb', true) THEN
    RAISE EXCEPTION 'simulated run failure';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER test_fail_run BEFORE INSERT ON public.recurring_broadcast_runs
  FOR EACH ROW EXECUTE FUNCTION test.fail_run_for_rb();

DO $$
DECLARE
  v_now TIMESTAMPTZ := pg_temp.t_now();
  v_msk_date DATE := (v_now AT TIME ZONE 'Europe/Moscow')::date;
  v_dow_tomorrow INT := EXTRACT(ISODOW FROM v_msk_date + 1)::INT;
  v_expected_next TIMESTAMPTZ := (v_msk_date + 1 + TIME '12:00') AT TIME ZONE 'Europe/Moscow';
  v_rb_run UUID := pg_temp.tid('rb_run');
  v_rb_null UUID;
  v_rb_inactive UUID;
  v_rb_broken UUID;
  v_result RECORD;
  v_runs_before BIGINT;
BEGIN
  INSERT INTO public.recurring_broadcasts (name, template, city, weekdays, send_time, title, body, body_city, is_active, next_run_at)
  VALUES ('broken', 'new_jobs_near_metro', 'moscow', ARRAY[v_dow_tomorrow], '12:00', 't', 'b', 'bc', true, v_now + INTERVAL '2 hours')
  RETURNING id INTO v_rb_broken;
  PERFORM set_config('test.fail_rb', v_rb_broken::TEXT, true);
  INSERT INTO public.recurring_broadcasts (name, template, weekdays, send_time, title, body, body_city, is_active, next_run_at)
  VALUES ('active without schedule', 'new_jobs_near_metro', ARRAY[v_dow_tomorrow], '12:00', 't', 'b', 'bc', true, NULL)
  RETURNING id INTO v_rb_null;
  INSERT INTO public.recurring_broadcasts (name, template, weekdays, send_time, title, body, body_city, is_active, next_run_at)
  VALUES ('inactive but due', 'new_jobs_near_metro', ARRAY[v_dow_tomorrow], '12:00', 't', 'b', 'bc', false, v_now - INTERVAL '1 hour')
  RETURNING id INTO v_rb_inactive;
  UPDATE public.recurring_broadcasts SET next_run_at = v_now + INTERVAL '2 hours' WHERE id = v_rb_run;
  SELECT count(*) INTO v_runs_before FROM public.recurring_broadcast_runs;

  SELECT * INTO v_result FROM app_internal.process_recurring_broadcasts(v_now + INTERVAL '1 hour');
  ASSERT (v_result.recurring_runs, v_result.scheduled_sent) = (0, 0), format('before next_run_at: %s', v_result);
  ASSERT (SELECT count(*) FROM public.recurring_broadcast_runs) = v_runs_before, 'nothing ran before next_run_at';
  ASSERT (SELECT rb.next_run_at FROM public.recurring_broadcasts rb WHERE rb.id = v_rb_null) = v_expected_next,
    'active row without next_run_at gets one computed instead of running';

  SELECT * INTO v_result FROM app_internal.process_recurring_broadcasts(v_now + INTERVAL '2 hours');
  ASSERT (v_result.recurring_runs, v_result.scheduled_sent) = (1, 0), format('at next_run_at: %s', v_result);
  ASSERT (SELECT array_agg(ROW(r.trigger, r.admin_id, r.ran_at, r.recipient_count)::TEXT)
          FROM public.recurring_broadcast_runs r
          WHERE r.recurring_broadcast_id = v_rb_run AND r.ran_at = v_now + INTERVAL '2 hours')
       = ARRAY[ROW('cron', NULL::UUID, v_now + INTERVAL '2 hours', 9)::TEXT], 'cron run journaled';
  ASSERT (SELECT ARRAY[rb.last_run_at, rb.next_run_at] FROM public.recurring_broadcasts rb WHERE rb.id = v_rb_run)
       = ARRAY[v_now + INTERVAL '2 hours', v_expected_next];
  ASSERT (SELECT count(*) FROM app_internal.engagement_pushes ep WHERE ep.data->>'recurringBroadcastId' = v_rb_run::TEXT) = 9,
    'same-day cron run adds no pushes';
  ASSERT (SELECT count(*) FROM public.recurring_broadcast_runs r WHERE r.recurring_broadcast_id IN (v_rb_null, v_rb_inactive)) = 0,
    'inactive rows are never run';

  ASSERT (SELECT ROW(rb.last_run_at, rb.next_run_at)::TEXT FROM public.recurring_broadcasts rb WHERE rb.id = v_rb_broken)
       = ROW(NULL::TIMESTAMPTZ, v_expected_next)::TEXT,
    'a throwing run consumes its slot: next_run_at advanced, last_run_at untouched';
  ASSERT (SELECT count(*) FROM public.recurring_broadcast_runs r WHERE r.recurring_broadcast_id = v_rb_broken) = 0
     AND (SELECT count(*) FROM app_internal.engagement_pushes ep WHERE ep.data->>'recurringBroadcastId' = v_rb_broken::TEXT) = 0,
    'the failed run left no runs row and no pushes';
  PERFORM set_config('test.fail_rb', '', true);

  RAISE NOTICE 'ok: process_recurring_broadcasts (recurring part)';
END $$;

DROP TRIGGER test_fail_run ON public.recurring_broadcast_runs;
DROP FUNCTION test.fail_run_for_rb();

-- Bug 1: scheduled one-off broadcasts are sent by the same tick.
DO $$
DECLARE
  v_admin UUID := pg_temp.tid('adm_biz');
  v_due UUID;
  v_future UUID;
  v_sent UUID;
  v_bad UUID;
  v_result RECORD;
  v_audit RECORD;
BEGIN
  INSERT INTO public.broadcasts (segment, title, body, scheduled_for, created_by)
  VALUES (jsonb_build_object('ids', jsonb_build_array(pg_temp.tid('bar_a'), pg_temp.tid('bar_b'), pg_temp.tid('bar_l'))),
          'Запланировано', 'Текст рассылки', now() - INTERVAL '1 hour', v_admin)
  RETURNING id INTO v_due;
  INSERT INTO public.broadcasts (segment, title, body, scheduled_for, created_by)
  VALUES ('{"account_type":"barista"}', 'Позже', 'b', now() + INTERVAL '1 day', v_admin) RETURNING id INTO v_future;
  INSERT INTO public.broadcasts (segment, title, body, scheduled_for, sent_at, delivered_count, created_by)
  VALUES ('{"account_type":"barista"}', 'Уже', 'b', now() - INTERVAL '2 days', now() - INTERVAL '1 day', 3, v_admin) RETURNING id INTO v_sent;
  INSERT INTO public.broadcasts (segment, title, body, scheduled_for, created_by)
  VALUES ('{"ids":["not-a-uuid"]}', 'Сломано', 'b', now() - INTERVAL '1 hour', v_admin) RETURNING id INTO v_bad;

  SELECT * INTO v_result FROM app_internal.process_recurring_broadcasts(now());
  ASSERT (v_result.recurring_runs, v_result.scheduled_sent) = (0, 1), format('scheduled tick: %s', v_result);

  ASSERT (SELECT array_agg(ROW(u.email, n.kind, n.title, n.body, n.data)::TEXT ORDER BY u.email)
          FROM public.notifications n JOIN public.users u ON u.id = n.user_id
          WHERE n.data->>'broadcast_id' = v_due::TEXT)
       = ARRAY[
           ROW('bar-a@test.local', 'broadcast', 'Запланировано', 'Текст рассылки', jsonb_build_object('broadcast_id', v_due))::TEXT,
           ROW('bar-b@test.local', 'broadcast', 'Запланировано', 'Текст рассылки', jsonb_build_object('broadcast_id', v_due))::TEXT],
    'notifications for the two non-admin ids';
  ASSERT (SELECT array_agg(d.recipient_id ORDER BY d.recipient_id) FROM app_internal.apns_dispatch_log d WHERE d.kind = 'broadcast')
       = (SELECT array_agg(x ORDER BY x) FROM unnest(ARRAY[pg_temp.tid('bar_a'), pg_temp.tid('bar_b')]) x),
    'the notifications trigger handed both to send-push';
  ASSERT (SELECT ROW(b.sent_at, b.delivered_count)::TEXT FROM public.broadcasts b WHERE b.id = v_due) = ROW(now(), 2)::TEXT,
    'sent_at and delivered_count set';

  SELECT * INTO v_audit FROM public.audit_log a WHERE a.action = 'broadcast.send' AND a.target_id = v_due;
  ASSERT (v_audit.admin_id, v_audit.target_table, v_audit.after, v_audit.reason)
       = (v_admin, 'broadcasts', '{"delivered_count": 2}'::jsonb, 'scheduled send by process_recurring_broadcasts'),
    format('audit row written on behalf of created_by: %s', to_jsonb(v_audit));

  ASSERT (SELECT array_agg(b.sent_at IS NULL ORDER BY b.id) FROM public.broadcasts b WHERE b.id IN (v_future, v_bad)) = ARRAY[true, true],
    'future and broken broadcasts stay unsent';
  ASSERT (SELECT b.delivered_count FROM public.broadcasts b WHERE b.id = v_sent) = 3, 'already sent broadcast untouched';
  ASSERT (SELECT count(*) FROM public.notifications n WHERE n.kind = 'broadcast') = 2,
    'recurring history rows (sent_at set) are never re-sent as one-off broadcasts';

  -- Re-running the tick is a no-op for the already-sent one.
  SELECT * INTO v_result FROM app_internal.process_recurring_broadcasts(now());
  ASSERT (v_result.recurring_runs, v_result.scheduled_sent) = (0, 0), format('second tick: %s', v_result);
  RAISE NOTICE 'ok: scheduled broadcasts are sent by process_recurring_broadcasts';
END $$;

-- ---------------------------------------------------------------------------
-- 7. Segment grammar (bugs 2, 3 + actively_looking, max_build, is_admin)
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_now TIMESTAMPTZ := pg_temp.t_now();
  v_s1 UUID := test.make_user('seg-1@test.local', 'barista');
  v_s2 UUID := test.make_user('seg-2@test.local', 'barista');
  v_s3 UUID := test.make_user('seg-3@test.local', 'business');
  v_s4 UUID := test.make_user('seg-4@test.local', 'barista');
  v_s5 UUID := test.make_user('seg-5@test.local', 'barista');
  v_multi UUID := test.make_user('seg-multi@test.local', 'business');
  v_multi_biz UUID;
  v_ids JSONB;
  v_denied BOOLEAN := false;
BEGIN
  -- Segment-only users: keep them out of the recurring broadcast audiences.
  UPDATE public.barista_profiles SET is_actively_looking = false WHERE user_id IN (v_s1, v_s2, v_s4, v_s5);
  INSERT INTO public.user_activity (user_id, last_seen_at) VALUES (v_s1, v_now - INTERVAL '1 day'), (v_s4, v_now - INTERVAL '40 days');
  INSERT INTO public.device_tokens (user_id, device_token, environment, last_seen_at) VALUES (v_s2, 'tok-s2', 'web', v_now - INTERVAL '2 days');
  INSERT INTO auth.sessions (user_id, refreshed_at) VALUES (v_s3, (v_now - INTERVAL '3 days') AT TIME ZONE 'UTC');
  v_ids := jsonb_build_array(v_s1, v_s2, v_s3, v_s4, v_s5, pg_temp.tid('bar_l'));

  ASSERT pg_temp.segment(jsonb_build_object('ids', v_ids)) = ARRAY['seg-1@test.local', 'seg-2@test.local', 'seg-3@test.local', 'seg-4@test.local', 'seg-5@test.local'],
    'ids: admin excluded even when listed';
  ASSERT pg_temp.segment(jsonb_build_object('ids', v_ids, 'last_active_after', v_now - INTERVAL '30 days'))
       = ARRAY['seg-1@test.local', 'seg-2@test.local', 'seg-3@test.local'],
    'last_active_after reads user_activity, device_tokens and auth.sessions';
  ASSERT pg_temp.segment(jsonb_build_object('ids', v_ids, 'last_active_after', v_now - INTERVAL '30 days', 'account_type', 'business'))
       = ARRAY['seg-3@test.local'], 'account_type still applies';

  SELECT id INTO v_multi_biz FROM public.businesses WHERE owner_id = v_multi;
  INSERT INTO public.branches (business_id, name, city, created_at) VALUES
    (v_multi_biz, 'first', 'moscow', v_now - INTERVAL '2 days'),
    (v_multi_biz, 'second', 'spb', v_now - INTERVAL '1 day');
  v_ids := jsonb_build_array(v_multi, pg_temp.tid('bar_a'), pg_temp.tid('bar_f'), pg_temp.tid('biz_2'));
  ASSERT pg_temp.segment(jsonb_build_object('ids', v_ids, 'city', 'spb')) = ARRAY['bar-a@test.local', 'seg-multi@test.local'],
    'city matches barista_profiles.city or ANY branch city (not only the first branch)';
  ASSERT pg_temp.segment(jsonb_build_object('ids', v_ids, 'city', 'moscow')) = ARRAY['bar-f@test.local', 'biz-2@test.local', 'seg-multi@test.local'];
  ASSERT pg_temp.segment(jsonb_build_object('ids', v_ids, 'city', 'kazan')) = '{}'::TEXT[];

  v_ids := jsonb_build_array(pg_temp.tid('bar_a'), pg_temp.tid('bar_i'), pg_temp.tid('biz_1'));
  ASSERT pg_temp.segment(jsonb_build_object('ids', v_ids, 'actively_looking', true)) = ARRAY['bar-a@test.local'];
  ASSERT pg_temp.segment(jsonb_build_object('ids', v_ids, 'actively_looking', false)) = ARRAY['bar-i@test.local'];
  ASSERT pg_temp.segment(jsonb_build_object('ids', v_ids)) = ARRAY['bar-a@test.local', 'bar-i@test.local', 'biz-1@test.local'];

  UPDATE public.user_activity SET last_build = 85, last_platform = 'ios' WHERE user_id = pg_temp.tid('bar_a');
  UPDATE public.user_activity SET last_build = 87, last_platform = 'ios' WHERE user_id = pg_temp.tid('bar_b');
  UPDATE public.user_activity SET last_build = NULL, last_platform = 'web' WHERE user_id = pg_temp.tid('bar_c');
  -- bar_d: heartbeat without platform/build (old iOS build); bar_n: no heartbeat at all
  v_ids := jsonb_build_array(pg_temp.tid('bar_a'), pg_temp.tid('bar_b'), pg_temp.tid('bar_c'), pg_temp.tid('bar_d'), pg_temp.tid('bar_n'));
  ASSERT pg_temp.segment(jsonb_build_object('ids', v_ids, 'max_build', 86)) = ARRAY['bar-a@test.local', 'bar-d@test.local', 'bar-n@test.local'],
    'max_build keeps builds <= value, NULL builds and users without a heartbeat; web heartbeats excluded';
  ASSERT pg_temp.segment(jsonb_build_object('ids', v_ids, 'max_build', 87)) = ARRAY['bar-a@test.local', 'bar-b@test.local', 'bar-d@test.local', 'bar-n@test.local'];
  ASSERT pg_temp.segment(jsonb_build_object('ids', v_ids)) = ARRAY['bar-a@test.local', 'bar-b@test.local', 'bar-c@test.local', 'bar-d@test.local', 'bar-n@test.local'],
    'without max_build the web user is a normal recipient';

  v_ids := jsonb_build_array(pg_temp.tid('bar_a'), pg_temp.tid('bar_j'), pg_temp.tid('bar_k'));
  ASSERT pg_temp.segment(jsonb_build_object('ids', v_ids)) = ARRAY['bar-a@test.local'], 'banned and inactive excluded';

  -- public wrapper
  PERFORM test.act_as(pg_temp.tid('bar_a'));
  BEGIN
    PERFORM count(*) FROM public.admin_broadcast_segment_recipients('{}');
  EXCEPTION WHEN insufficient_privilege THEN
    v_denied := true;
  END;
  ASSERT v_denied, 'admin_broadcast_segment_recipients: non-admin gets 42501';
  PERFORM test.act_as(pg_temp.tid('adm_biz'));
  ASSERT pg_temp.emails_of(ARRAY(SELECT r.user_id FROM public.admin_broadcast_segment_recipients(jsonb_build_object('ids', v_ids)) r))
       = ARRAY['bar-a@test.local'], 'public wrapper delegates to the internal resolver';
  PERFORM test.act_as(NULL);
  RAISE NOTICE 'ok: segment grammar';
END $$;

-- ---------------------------------------------------------------------------
-- 8. Admin RPCs
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_user UUID := pg_temp.tid('bar_a');
  v_rb UUID := pg_temp.tid('rb_run');
  v_denied INT := 0;
BEGIN
  PERFORM test.act_as(v_user);
  BEGIN
    PERFORM public.admin_recurring_broadcast_upsert(NULL, 'x', 'new_jobs_near_metro', NULL, ARRAY[1], '12:00', 3, 1, 't', 'b', 'bc', false, 'reason long enough');
  EXCEPTION WHEN insufficient_privilege THEN v_denied := v_denied + 1; END;
  BEGIN
    PERFORM public.admin_recurring_broadcast_set_active(v_rb, false, 'reason long enough');
  EXCEPTION WHEN insufficient_privilege THEN v_denied := v_denied + 1; END;
  BEGIN
    PERFORM count(*) FROM public.admin_recurring_broadcast_preview(v_rb);
  EXCEPTION WHEN insufficient_privilege THEN v_denied := v_denied + 1; END;
  BEGIN
    PERFORM public.admin_recurring_broadcast_run_now(v_rb, 'reason long enough');
  EXCEPTION WHEN insufficient_privilege THEN v_denied := v_denied + 1; END;
  BEGIN
    PERFORM public.admin_social_digest('spb', 7);
  EXCEPTION WHEN insufficient_privilege THEN v_denied := v_denied + 1; END;
  BEGIN
    PERFORM public.admin_broadcast_send(v_rb, 'reason long enough');
  EXCEPTION WHEN insufficient_privilege THEN v_denied := v_denied + 1; END;
  ASSERT v_denied = 6, format('every admin RPC raises 42501 for a non-admin, got %s of 6', v_denied);
  PERFORM test.act_as(NULL);
  RAISE NOTICE 'ok: admin RPCs reject non-admins';
END $$;

DO $$
DECLARE
  v_now TIMESTAMPTZ := pg_temp.t_now();
  v_msk_date DATE := (v_now AT TIME ZONE 'Europe/Moscow')::date;
  v_dow_tomorrow INT := EXTRACT(ISODOW FROM v_msk_date + 1)::INT;
  v_dow_after INT := EXTRACT(ISODOW FROM v_msk_date + 2)::INT;
  v_expected_next TIMESTAMPTZ := (v_msk_date + 1 + TIME '12:00') AT TIME ZONE 'Europe/Moscow';
  v_expected_next_0915 TIMESTAMPTZ := (v_msk_date + 1 + TIME '09:15') AT TIME ZONE 'Europe/Moscow';
  v_admin UUID := pg_temp.tid('adm_biz');
  v_id UUID;
  v_row RECORD;
  v_audit RECORD;
  v_err TEXT;
BEGIN
  PERFORM test.act_as(v_admin);

  v_id := public.admin_recurring_broadcast_upsert(
    NULL, 'Тестовая', 'new_jobs_near_metro', 'spb', ARRAY[v_dow_tomorrow], '09:15', 2, 2,
    'Заголовок', 'Тело {metro}', 'Тело {city}', true, 'create for the test');
  SELECT * INTO v_row FROM public.recurring_broadcasts rb WHERE rb.id = v_id;
  ASSERT (v_row.name, v_row.template, v_row.city, v_row.weekdays, v_row.send_time, v_row.lookback_days, v_row.min_count,
          v_row.title, v_row.body, v_row.body_city, v_row.is_active, v_row.last_run_at, v_row.next_run_at, v_row.created_by)
       IS NOT DISTINCT FROM ('Тестовая', 'new_jobs_near_metro', 'spb', ARRAY[v_dow_tomorrow], TIME '09:15', 2, 2,
          'Заголовок', 'Тело {metro}', 'Тело {city}', true, NULL::TIMESTAMPTZ, v_expected_next_0915, v_admin),
    format('upsert insert: %s', to_jsonb(v_row));
  SELECT * INTO v_audit FROM public.audit_log a WHERE a.action = 'recurring_broadcast.upsert' AND a.target_id = v_id;
  ASSERT (v_audit.admin_id, v_audit.target_table, v_audit.before, v_audit.after->>'name', v_audit.after->>'is_active', v_audit.reason)
       IS NOT DISTINCT FROM (v_admin, 'recurring_broadcasts', NULL::JSONB, 'Тестовая', 'true', 'create for the test'),
    format('upsert insert audit: %s', to_jsonb(v_audit));

  ASSERT public.admin_recurring_broadcast_upsert(
    v_id, 'Тестовая 2', 'baristas_nearby', NULL, ARRAY[v_dow_tomorrow, v_dow_after], '12:00', NULL, NULL,
    'З2', 'Т2 {branch}', 'Т2 {city}', false, 'update for the test') = v_id, 'upsert update returns the same id';
  SELECT * INTO v_row FROM public.recurring_broadcasts rb WHERE rb.id = v_id;
  ASSERT (v_row.name, v_row.template, v_row.city, v_row.weekdays, v_row.send_time, v_row.lookback_days, v_row.min_count,
          v_row.title, v_row.body, v_row.body_city, v_row.is_active, v_row.next_run_at)
       IS NOT DISTINCT FROM ('Тестовая 2', 'baristas_nearby', NULL::TEXT, ARRAY[v_dow_tomorrow, v_dow_after], TIME '12:00', 3, 1,
          'З2', 'Т2 {branch}', 'Т2 {city}', false, NULL::TIMESTAMPTZ),
    format('upsert update (defaults for NULL lookback/min, next_run_at NULL when inactive): %s', to_jsonb(v_row));
  ASSERT (SELECT array_agg(ROW(a.before->>'name', a.after->>'name')::TEXT ORDER BY a.id)
          FROM public.audit_log a WHERE a.action = 'recurring_broadcast.upsert' AND a.target_id = v_id)
       = ARRAY[ROW(NULL::TEXT, 'Тестовая')::TEXT, ROW('Тестовая', 'Тестовая 2')::TEXT], 'upsert audit before/after';

  BEGIN
    PERFORM public.admin_recurring_broadcast_upsert(v_id, 'x', 'baristas_nearby', NULL, ARRAY[1], '12:00', 3, 1, 't', 'b', 'bc', false, 'short');
    v_err := NULL;
  EXCEPTION WHEN invalid_parameter_value THEN v_err := SQLSTATE; END;
  ASSERT v_err = '22023', 'reason shorter than 10 chars -> 22023';
  BEGIN
    PERFORM public.admin_recurring_broadcast_upsert(v_id, 'x', 'baristas_nearby', NULL, ARRAY[1], '12:00', 3, 1, '', 'b', 'bc', false, 'reason long enough');
    v_err := NULL;
  EXCEPTION WHEN invalid_parameter_value THEN v_err := SQLSTATE; END;
  ASSERT v_err = '22023', 'empty title -> 22023';
  BEGIN
    PERFORM public.admin_recurring_broadcast_upsert(v_id, 'x', 'baristas_nearby', NULL, ARRAY[1], '12:00', 3, 1, 't', repeat('b', 2001), 'bc', false, 'reason long enough');
    v_err := NULL;
  EXCEPTION WHEN invalid_parameter_value THEN v_err := SQLSTATE; END;
  ASSERT v_err = '22023', 'body over 2000 chars -> 22023';
  BEGIN
    PERFORM public.admin_recurring_broadcast_upsert(NULL, 'bad template', 'something_else', NULL, ARRAY[1], '12:00', 3, 1, 't', 'b', 'bc', false, 'reason long enough');
    v_err := NULL;
  EXCEPTION WHEN check_violation THEN v_err := SQLSTATE; END;
  ASSERT v_err = '23514', 'unknown template -> check violation';
  BEGIN
    PERFORM public.admin_recurring_broadcast_upsert(NULL, 'bad weekday', 'baristas_nearby', NULL, ARRAY[0, 8], '12:00', 3, 1, 't', 'b', 'bc', false, 'reason long enough');
    v_err := NULL;
  EXCEPTION WHEN check_violation THEN v_err := SQLSTATE; END;
  ASSERT v_err = '23514', 'weekday outside 1..7 -> check violation';
  BEGIN
    PERFORM public.admin_recurring_broadcast_upsert(uuid_generate_v4(), 'x', 'baristas_nearby', NULL, ARRAY[1], '12:00', 3, 1, 't', 'b', 'bc', false, 'reason long enough');
    v_err := NULL;
  EXCEPTION WHEN SQLSTATE '02000' THEN v_err := SQLSTATE; END;
  ASSERT v_err = '02000', 'unknown id -> 02000';

  PERFORM public.admin_recurring_broadcast_set_active(v_id, true, 'switch on for the test');
  SELECT * INTO v_row FROM public.recurring_broadcasts rb WHERE rb.id = v_id;
  ASSERT (v_row.is_active, v_row.next_run_at) = (true, v_expected_next),
    'set_active(true) schedules the next run (tomorrow 12:00 MSK)';
  PERFORM public.admin_recurring_broadcast_set_active(v_id, false, 'switch off for the test');
  ASSERT (SELECT ROW(rb.is_active, rb.next_run_at)::TEXT FROM public.recurring_broadcasts rb WHERE rb.id = v_id) = ROW(false, NULL::TIMESTAMPTZ)::TEXT,
    'set_active(false) clears next_run_at';
  ASSERT (SELECT array_agg(ROW(a.before->>'is_active', a.after->>'is_active', a.reason)::TEXT ORDER BY a.id)
          FROM public.audit_log a WHERE a.action = 'recurring_broadcast.toggle' AND a.target_id = v_id)
       = ARRAY[ROW('false', 'true', 'switch on for the test')::TEXT, ROW('true', 'false', 'switch off for the test')::TEXT],
    'toggle audit rows';

  PERFORM test.act_as(NULL);
  RAISE NOTICE 'ok: admin_recurring_broadcast_upsert / set_active';
END $$;

DO $$
DECLARE
  v_admin UUID := pg_temp.tid('adm_biz');
  v_rb_run UUID := pg_temp.tid('rb_run');
  v_preview RECORD;
  v_runs_before BIGINT;
  v_n JSONB;
  v_run RECORD;
  v_audit RECORD;
BEGIN
  PERFORM test.act_as(v_admin);

  SELECT * INTO v_preview FROM public.admin_recurring_broadcast_preview(pg_temp.tid('rb_jobs_min3'));
  ASSERT (v_preview.recipient_count, v_preview.samples) = (7, jsonb_build_array(
      jsonb_build_object('title', 'Новые смены рядом', 'body', '3 новые смены у м. Чернышевская'),
      jsonb_build_object('title', 'Новые смены рядом', 'body', '5 новых смен в Петербурге'),
      jsonb_build_object('title', 'Новые смены рядом', 'body', '5 новых смен в Петербурге'),
      jsonb_build_object('title', 'Новые смены рядом', 'body', '5 новых смен в Петербурге'),
      jsonb_build_object('title', 'Новые смены рядом', 'body', '5 новых смен в Петербурге'))),
    format('preview: count + up to 5 {title, body} samples without ids: %s / %s', v_preview.recipient_count, v_preview.samples);
  SELECT * INTO v_preview FROM public.admin_recurring_broadcast_preview(v_rb_run);
  ASSERT (v_preview.recipient_count, jsonb_array_length(v_preview.samples)) = (9, 5), 'preview caps samples at 5';
  SELECT * INTO v_preview FROM public.admin_recurring_broadcast_preview(pg_temp.tid('rb_zero'));
  ASSERT (v_preview.recipient_count, v_preview.samples) = (0, '[]'::jsonb), 'preview of an empty audience';

  SELECT count(*) INTO v_runs_before FROM public.recurring_broadcast_runs r WHERE r.recurring_broadcast_id = v_rb_run;
  v_n := public.admin_recurring_broadcast_run_now(v_rb_run, 'manual run for the test');
  ASSERT v_n = '{"recipient_count": 9, "queued_count": 0, "push_mode": "on"}'::jsonb,
    format('run_now returns audience, queued (0: all deduped today) and mode, got %s', v_n);
  SELECT * INTO v_run FROM public.recurring_broadcast_runs r WHERE r.recurring_broadcast_id = v_rb_run ORDER BY r.id DESC LIMIT 1;
  ASSERT (v_run.trigger, v_run.admin_id, v_run.ran_at, v_run.recipient_count, v_run.queued_count, v_run.push_mode)
       = ('manual', v_admin, now(), 9, 0, 'on'), format('run_now runs row: %s', to_jsonb(v_run));
  ASSERT (SELECT count(*) FROM public.recurring_broadcast_runs r WHERE r.recurring_broadcast_id = v_rb_run) = v_runs_before + 1;
  ASSERT (SELECT count(*) FROM app_internal.engagement_pushes ep WHERE ep.data->>'recurringBroadcastId' = v_rb_run::TEXT) = 9,
    'run_now on the same Moscow day adds no pushes';
  SELECT * INTO v_audit FROM public.audit_log a WHERE a.action = 'recurring_broadcast.run' AND a.target_id = v_rb_run;
  ASSERT (v_audit.admin_id, v_audit.target_table, v_audit.before, v_audit.after, v_audit.reason)
       IS NOT DISTINCT FROM (v_admin, 'recurring_broadcasts', NULL::JSONB, '{"recipient_count": 9, "queued_count": 0, "push_mode": "on"}'::jsonb, 'manual run for the test'),
    format('run_now audit: %s', to_jsonb(v_audit));

  PERFORM test.act_as(NULL);
  RAISE NOTICE 'ok: admin_recurring_broadcast_preview / run_now';
END $$;

-- ---------------------------------------------------------------------------
-- 9. admin_social_digest (window relative to now(); every fixture job is
--    within 7 days, the admin / not-accepting / filled / inactive-branch ones
--    are excluded)
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_actual JSONB;
  v_err TEXT;
BEGIN
  PERFORM test.act_as(pg_temp.tid('adm_biz'));

  v_actual := public.admin_social_digest('spb', 7);
  ASSERT v_actual = jsonb_build_object(
    'city', 'spb',
    'city_name', 'Петербург',
    'days', 7,
    'jobs_count', 6,
    'stations', jsonb_build_array(
      jsonb_build_object('station', 'Чернышевская', 'count', 3),
      jsonb_build_object('station', 'Адмиралтейская', 'count', 1),
      jsonb_build_object('station', 'Площадь Восстания', 'count', 1)),
    'rate_min', 400,
    'rate_max', 650,
    'generated_at', now()
  ), format('social digest spb: %s', jsonb_pretty(v_actual));

  v_actual := public.admin_social_digest('moscow');
  ASSERT v_actual = jsonb_build_object(
    'city', 'moscow', 'city_name', 'Москва', 'days', 7, 'jobs_count', 1,
    'stations', jsonb_build_array(jsonb_build_object('station', 'Тверская', 'count', 1)),
    'rate_min', 700, 'rate_max', 700, 'generated_at', now()
  ), format('social digest moscow (default 7 days): %s', jsonb_pretty(v_actual));

  UPDATE public.jobs SET posted_at = now() - INTERVAL '100 days' WHERE id = pg_temp.tid('job_msk');
  v_actual := public.admin_social_digest('moscow', 500);
  ASSERT v_actual = jsonb_build_object(
    'city', 'moscow', 'city_name', 'Москва', 'days', 90, 'jobs_count', 0,
    'stations', '[]'::jsonb, 'rate_min', NULL, 'rate_max', NULL, 'generated_at', now()
  ), format('social digest with no jobs, days clamped to 90: %s', jsonb_pretty(v_actual));
  UPDATE public.jobs SET posted_at = pg_temp.t_now() - INTERVAL '1 day' WHERE id = pg_temp.tid('job_msk');

  BEGIN
    PERFORM public.admin_social_digest('kazan', 7);
    v_err := NULL;
  EXCEPTION WHEN invalid_parameter_value THEN v_err := SQLSTATE; END;
  ASSERT v_err = '22023', 'unknown city -> 22023';

  PERFORM test.act_as(NULL);
  RAISE NOTICE 'ok: admin_social_digest';
END $$;

-- ---------------------------------------------------------------------------
-- 10. Grants, cron, RLS, seeds, idempotent re-apply
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  ASSERT (
    SELECT ARRAY[
      has_function_privilege('anon', 'public.admin_recurring_broadcast_upsert(uuid,text,text,text,int[],time,int,int,text,text,text,boolean,text)', 'EXECUTE'),
      has_function_privilege('authenticated', 'public.admin_recurring_broadcast_upsert(uuid,text,text,text,int[],time,int,int,text,text,text,boolean,text)', 'EXECUTE'),
      has_function_privilege('anon', 'public.admin_recurring_broadcast_set_active(uuid,boolean,text)', 'EXECUTE'),
      has_function_privilege('authenticated', 'public.admin_recurring_broadcast_set_active(uuid,boolean,text)', 'EXECUTE'),
      has_function_privilege('anon', 'public.admin_recurring_broadcast_preview(uuid)', 'EXECUTE'),
      has_function_privilege('authenticated', 'public.admin_recurring_broadcast_preview(uuid)', 'EXECUTE'),
      has_function_privilege('anon', 'public.admin_recurring_broadcast_run_now(uuid,text)', 'EXECUTE'),
      has_function_privilege('authenticated', 'public.admin_recurring_broadcast_run_now(uuid,text)', 'EXECUTE'),
      has_function_privilege('anon', 'public.admin_social_digest(text,int)', 'EXECUTE'),
      has_function_privilege('authenticated', 'public.admin_social_digest(text,int)', 'EXECUTE'),
      has_function_privilege('anon', 'public.admin_broadcast_segment_recipients(jsonb)', 'EXECUTE'),
      has_function_privilege('authenticated', 'public.admin_broadcast_segment_recipients(jsonb)', 'EXECUTE'),
      has_function_privilege('anon', 'public.admin_broadcast_send(uuid,text)', 'EXECUTE'),
      has_function_privilege('authenticated', 'public.admin_broadcast_send(uuid,text)', 'EXECUTE'),
      has_function_privilege('service_role', 'public.admin_broadcast_send(uuid,text)', 'EXECUTE')
    ]
  ) = ARRAY[false, true, false, true, false, true, false, true, false, true, false, true, false, true, true],
    'public admin RPCs: authenticated + service_role only';

  ASSERT (
    SELECT ARRAY[
      has_function_privilege('authenticated', 'app_internal.next_recurring_run(int[],time,timestamptz)', 'EXECUTE'),
      has_function_privilege('authenticated', 'app_internal.recurring_broadcast_recipients(uuid,timestamptz)', 'EXECUTE'),
      has_function_privilege('authenticated', 'app_internal.broadcast_segment_recipients(jsonb)', 'EXECUTE'),
      has_function_privilege('authenticated', 'app_internal.broadcast_send(uuid,uuid,text)', 'EXECUTE'),
      has_function_privilege('authenticated', 'app_internal.run_recurring_broadcast(uuid,text,uuid,timestamptz)', 'EXECUTE'),
      has_function_privilege('authenticated', 'app_internal.process_recurring_broadcasts(timestamptz)', 'EXECUTE'),
      has_function_privilege('anon', 'app_internal.process_recurring_broadcasts(timestamptz)', 'EXECUTE'),
      has_function_privilege('service_role', 'app_internal.process_recurring_broadcasts(timestamptz)', 'EXECUTE'),
      has_function_privilege('service_role', 'app_internal.run_recurring_broadcast(uuid,text,uuid,timestamptz)', 'EXECUTE')
    ]
  ) = ARRAY[false, false, false, false, false, false, false, true, true],
    'app_internal functions: service_role only';

  ASSERT (
    SELECT ARRAY[
      has_table_privilege('authenticated', 'public.recurring_broadcasts', 'SELECT'),
      has_table_privilege('authenticated', 'public.recurring_broadcasts', 'INSERT'),
      has_table_privilege('authenticated', 'public.recurring_broadcasts', 'UPDATE'),
      has_table_privilege('authenticated', 'public.recurring_broadcasts', 'DELETE'),
      has_table_privilege('anon', 'public.recurring_broadcasts', 'SELECT'),
      has_table_privilege('service_role', 'public.recurring_broadcasts', 'INSERT'),
      has_table_privilege('authenticated', 'public.recurring_broadcast_runs', 'SELECT'),
      has_table_privilege('authenticated', 'public.recurring_broadcast_runs', 'INSERT'),
      has_table_privilege('service_role', 'public.recurring_broadcast_runs', 'INSERT')
    ]
  ) = ARRAY[true, false, false, false, false, true, true, false, true],
    'tables: authenticated reads (through RLS), only service_role writes';

  ASSERT (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.recurring_broadcasts'::regclass)
     AND (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.recurring_broadcast_runs'::regclass),
    'RLS enabled on both tables';
  ASSERT (SELECT array_agg(p.polname::TEXT ORDER BY p.polname) FROM pg_policy p
          WHERE p.polrelid IN ('public.recurring_broadcasts'::regclass, 'public.recurring_broadcast_runs'::regclass))
       = ARRAY['Admins read recurring broadcast runs', 'Admins read recurring broadcasts'], 'admin-only SELECT policies';

  ASSERT (SELECT ARRAY[j.schedule, j.command] FROM cron.job j WHERE j.jobname = 'process_recurring_broadcasts')
       = ARRAY['*/15 * * * *', 'SELECT app_internal.process_recurring_broadcasts();'],
    'cron: process_recurring_broadcasts every 15 minutes';

  ASSERT (SELECT array_agg(ROW(rb.name, rb.template, rb.city, rb.weekdays, rb.send_time, rb.lookback_days, rb.min_count,
                               rb.title, rb.body, rb.body_city, rb.is_active, rb.created_by)::TEXT ORDER BY rb.template)
          FROM public.recurring_broadcasts rb WHERE rb.name IN ('Смены у метро — вт/пт', 'Бариста рядом — вт/пт'))
       = ARRAY[
           ROW('Бариста рядом — вт/пт', 'baristas_nearby', NULL::TEXT, ARRAY[2, 5], TIME '12:00', 3, 1,
               'Бариста рядом с вашей точкой', 'Ищут смены у м. {metro}: {count} {baristas}', 'Ищут смены в {city}: {count} {baristas}', false, NULL::UUID)::TEXT,
           ROW('Смены у метро — вт/пт', 'new_jobs_near_metro', NULL::TEXT, ARRAY[2, 5], TIME '12:00', 3, 1,
               'Новые смены рядом', '{count} {shifts} у м. {metro}', '{count} {shifts} в {city}', false, NULL::UUID)::TEXT],
    'seeded templates';

  ASSERT (SELECT array_agg(c.column_name::TEXT ORDER BY c.column_name) FROM information_schema.columns c
          WHERE c.table_schema = 'public' AND c.table_name = 'user_activity' AND c.column_name IN ('last_platform', 'last_build'))
       = ARRAY['last_build', 'last_platform'], 'user_activity.last_platform / last_build';
  ASSERT (SELECT array_agg(c.column_name::TEXT ORDER BY c.column_name) FROM information_schema.columns c
          WHERE c.table_schema = 'public' AND c.table_name = 'recurring_broadcast_runs' AND c.column_name IN ('queued_count', 'push_mode'))
       = ARRAY['push_mode', 'queued_count'], 'recurring_broadcast_runs.queued_count / push_mode';

  RAISE NOTICE 'ok: grants, RLS, cron, seeds';
END $$;

\ir ../../migrations/147_recurring_broadcasts.sql

DO $$
BEGIN
  ASSERT (SELECT count(*) FROM public.recurring_broadcasts rb WHERE rb.name IN ('Смены у метро — вт/пт', 'Бариста рядом — вт/пт')) = 2,
    're-apply: seeds not duplicated';
  ASSERT (SELECT count(*) FROM public.recurring_broadcasts rb WHERE rb.id = pg_temp.tid('rb_run') AND rb.last_run_at IS NOT NULL) = 1,
    're-apply: existing rows untouched';
  ASSERT (SELECT count(*) FROM cron.job j WHERE j.jobname = 'process_recurring_broadcasts') = 1;
  RAISE NOTICE 'ok: migration re-applies cleanly';
END $$;

ROLLBACK;

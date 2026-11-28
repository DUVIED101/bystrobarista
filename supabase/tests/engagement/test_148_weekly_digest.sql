-- Tests for 148_weekly_digest.sql. Run through run.sh (fixtures + migrations
-- are applied first). Reference moment: Monday 2026-11-23 11:00 MSK, so the
-- digest window is [2026-11-16 11:00, 2026-11-23 11:00) MSK. Rows created by
-- the trigger get visible_since = now() (the session clock), which is always
-- after that moment and therefore never inside the window.
BEGIN;

CREATE TEMP TABLE test_ids (k TEXT PRIMARY KEY, id UUID NOT NULL) ON COMMIT DROP;

CREATE FUNCTION pg_temp.make_branch(p_owner UUID, p_city TEXT, p_station TEXT, p_active BOOLEAN DEFAULT true)
RETURNS UUID
LANGUAGE sql
AS $$
  INSERT INTO public.branches (business_id, name, city, metro_station, is_active)
  SELECT b.id, COALESCE(p_station, p_city), p_city, p_station, p_active
  FROM public.businesses b WHERE b.owner_id = p_owner
  RETURNING id;
$$;

CREATE FUNCTION pg_temp.make_job(p_branch UUID, p_posted TIMESTAMPTZ, p_comp JSONB, p_status TEXT DEFAULT 'open')
RETURNS UUID
LANGUAGE sql
AS $$
  INSERT INTO public.jobs (business_id, business_owner_id, branch_id, status, compensation, posted_at, created_at)
  SELECT br.business_id, b.owner_id, br.id, p_status, p_comp, p_posted, p_posted
  FROM public.branches br JOIN public.businesses b ON b.id = br.business_id
  WHERE br.id = p_branch
  RETURNING id;
$$;

-- ---------------------------------------------------------------------------
-- 1. visible_since trigger
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_bar UUID := test.make_user('t1-bar@test.local');
  v_backfill UUID := test.make_user('t1-backfill@test.local');
  v_hidden UUID := test.make_user('t1-hidden@test.local');
  v_preset TIMESTAMPTZ := '2026-01-01 12:00+03';
  v_backfill_updated TIMESTAMPTZ := '2026-10-01 10:00+03';
BEGIN
  ASSERT (SELECT visible_since FROM public.barista_profiles WHERE user_id = v_bar) = now(),
    'insert of a visible profile sets visible_since';

  UPDATE public.barista_profiles SET visible_since = v_preset WHERE user_id = v_bar;
  ASSERT (SELECT visible_since FROM public.barista_profiles WHERE user_id = v_bar) = now(),
    'a client-sent visible_since is ignored on a visible row';

  ALTER TABLE public.barista_profiles DISABLE TRIGGER zz_set_visible_since;
  UPDATE public.barista_profiles SET visible_since = v_preset WHERE user_id = v_bar;
  ALTER TABLE public.barista_profiles ENABLE TRIGGER zz_set_visible_since;
  UPDATE public.barista_profiles SET first_name = 'Ира' WHERE user_id = v_bar;
  ASSERT (SELECT visible_since FROM public.barista_profiles WHERE user_id = v_bar) = v_preset,
    'an already set visible_since is kept while visible';
  UPDATE public.barista_profiles SET visible_since = v_preset + INTERVAL '1 day' WHERE user_id = v_bar;
  ASSERT (SELECT visible_since FROM public.barista_profiles WHERE user_id = v_bar) = v_preset,
    'a client-sent change of visible_since is discarded';

  UPDATE public.barista_profiles SET profile_completeness = 29 WHERE user_id = v_bar;
  ASSERT (SELECT visible_since FROM public.barista_profiles WHERE user_id = v_bar) IS NULL,
    'completeness below 30 clears visible_since';

  UPDATE public.barista_profiles SET profile_completeness = 30 WHERE user_id = v_bar;
  ASSERT (SELECT visible_since FROM public.barista_profiles WHERE user_id = v_bar) = now(),
    'reaching completeness 30 sets visible_since again';

  UPDATE public.barista_profiles SET is_actively_looking = false WHERE user_id = v_bar;
  ASSERT (SELECT visible_since FROM public.barista_profiles WHERE user_id = v_bar) IS NULL,
    'is_actively_looking = false clears visible_since';

  UPDATE public.barista_profiles SET is_actively_looking = true WHERE user_id = v_bar;
  ASSERT (SELECT visible_since FROM public.barista_profiles WHERE user_id = v_bar) = now(),
    'is_actively_looking = true sets visible_since';

  UPDATE public.barista_profiles SET is_actively_looking = NULL WHERE user_id = v_bar;
  ASSERT (SELECT visible_since FROM public.barista_profiles WHERE user_id = v_bar) IS NULL,
    'is_actively_looking = NULL counts as hidden';
  UPDATE public.barista_profiles SET visible_since = v_preset WHERE user_id = v_bar;
  ASSERT (SELECT visible_since FROM public.barista_profiles WHERE user_id = v_bar) IS NULL,
    'a client-sent visible_since is ignored on a hidden row';

  -- Rows that existed before the trigger: visible_since is NULL on both.
  ALTER TABLE public.barista_profiles DISABLE TRIGGER zz_set_visible_since;
  ALTER TABLE public.barista_profiles DISABLE TRIGGER update_barista_profiles_updated_at;
  UPDATE public.barista_profiles
     SET visible_since = NULL, updated_at = v_backfill_updated
   WHERE user_id IN (v_backfill, v_hidden);
  UPDATE public.barista_profiles SET is_actively_looking = false WHERE user_id = v_hidden;
  ALTER TABLE public.barista_profiles ENABLE TRIGGER update_barista_profiles_updated_at;
  ALTER TABLE public.barista_profiles ENABLE TRIGGER zz_set_visible_since;
  INSERT INTO test_ids VALUES ('t1_backfill', v_backfill), ('t1_hidden', v_hidden);

  RAISE NOTICE 'ok: visible_since trigger';
END $$;

-- Re-applying the migration (idempotent) runs the backfill again. 153 is
-- re-applied right after: it CREATE OR REPLACEs the same functions with the
-- 30 % threshold, and re-running 148 alone would otherwise regress them back
-- to 20 % for the rest of this file.
\ir ../../migrations/148_weekly_digest.sql
\ir ../../migrations/153_profile_threshold_30.sql

DO $$
DECLARE
  v_backfill_updated TIMESTAMPTZ := '2026-10-01 10:00+03';
BEGIN
  ASSERT (
    SELECT ARRAY[bp.visible_since, bp.updated_at]
    FROM public.barista_profiles bp
    WHERE bp.user_id = (SELECT id FROM test_ids WHERE k = 't1_backfill')
  ) = ARRAY[v_backfill_updated, v_backfill_updated],
    'backfill: visible row gets visible_since = updated_at, updated_at untouched';

  ASSERT (
    SELECT ARRAY[bp.visible_since, bp.updated_at]
    FROM public.barista_profiles bp
    WHERE bp.user_id = (SELECT id FROM test_ids WHERE k = 't1_hidden')
  ) = ARRAY[NULL::TIMESTAMPTZ, v_backfill_updated],
    'backfill: hidden row stays NULL, updated_at untouched';

  RAISE NOTICE 'ok: visible_since backfill, migration re-applies cleanly';
END $$;

-- ---------------------------------------------------------------------------
-- 2. barista digest + process_weekly_digest('barista')
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_now TIMESTAMPTZ := '2026-11-23 11:00+03';
  v_owner UUID := test.make_user('t2-owner@test.local', 'business');
  v_admin_owner UUID := test.make_user('t2-admin-owner@test.local', 'business', true);
  v_closed_owner UUID := test.make_user('t2-closed-owner@test.local', 'business');
  v_b01 UUID := test.make_user('t2-b01-stations@test.local');
  v_b02 UUID := test.make_user('t2-b02-any@test.local');
  v_b03 UUID := test.make_user('t2-b03-moscow@test.local');
  v_b04 UUID := test.make_user('t2-b04-empty-city@test.local');
  v_b05 UUID := test.make_user('t2-b05-completeness-29@test.local');
  v_b06 UUID := test.make_user('t2-b06-seen-61d@test.local');
  v_b07 UUID := test.make_user('t2-b07-never-seen@test.local');
  v_b08 UUID := test.make_user('t2-b08-admin@test.local', 'barista', true);
  v_b09 UUID := test.make_user('t2-b09-banned@test.local');
  v_b10 UUID := test.make_user('t2-b10-inactive@test.local');
  v_b11 UUID := test.make_user('t2-b11-not-looking@test.local');
  v_b12 UUID := test.make_user('t2-b12-seen-60d@test.local');
  v_br_chern UUID := pg_temp.make_branch(v_owner, 'spb', 'Чернышевская');
  v_br_nevsky UUID := pg_temp.make_branch(v_owner, 'spb', 'Невский проспект');
  v_br_inactive UUID := pg_temp.make_branch(v_owner, 'spb', 'Чернышевская', false);
  v_br_msk UUID := pg_temp.make_branch(v_owner, 'moscow', 'Тверская');
  v_br_admin UUID := pg_temp.make_branch(v_admin_owner, 'spb', 'Чернышевская');
  v_br_closed UUID := pg_temp.make_branch(v_closed_owner, 'spb', 'Чернышевская');
  v_s1 UUID; v_s2 UUID; v_s3 UUID;
  v_n1 UUID; v_n2 UUID; v_n3 UUID; v_n4 UUID;
  v_m1 UUID;
  v_body_stations TEXT := 'Смены недели: 7 в Петербурге, 3 у ваших станций, до 650 ₽/ч';
  v_body_city TEXT := 'Смены недели: 7 в Петербурге, до 650 ₽/ч';
  v_body_moscow TEXT := 'Смены недели: 1 в Москве';
  v_data_stations JSONB;
  v_data_city JSONB;
  v_data_moscow JSONB;
  v_actual JSONB;
  v_expected JSONB;
BEGIN
  UPDATE public.businesses SET is_accepting_applications = false WHERE owner_id = v_closed_owner;

  -- 3 jobs at the barista's station, 4 elsewhere in spb; all inside the window.
  v_s1 := pg_temp.make_job(v_br_chern, v_now - INTERVAL '1 day', '{"type":"hourly","amount":500}');
  v_s2 := pg_temp.make_job(v_br_chern, v_now - INTERVAL '3 days', '{"type":"hourly","amount":"650"}');
  v_s3 := pg_temp.make_job(v_br_chern, v_now - INTERVAL '5 days', '{"type":"hourly","amount":600}');
  v_n1 := pg_temp.make_job(v_br_nevsky, v_now - INTERVAL '2 days', '{"type":"hourly","amount":400}');
  v_n2 := pg_temp.make_job(v_br_nevsky, v_now - INTERVAL '4 days', '{"type":"fixed","amount":5000}');
  v_n3 := pg_temp.make_job(v_br_nevsky, v_now - INTERVAL '6 days', NULL);
  v_n4 := pg_temp.make_job(v_br_nevsky, v_now - INTERVAL '6 days 23 hours', '{"type":"hourly","amount":550}');
  -- Excluded sources, each with a higher hourly rate than 650.
  PERFORM pg_temp.make_job(v_br_chern, v_now - INTERVAL '8 days', '{"type":"hourly","amount":900}');
  PERFORM pg_temp.make_job(v_br_chern, v_now, '{"type":"hourly","amount":950}');
  PERFORM pg_temp.make_job(v_br_chern, v_now - INTERVAL '1 day', '{"type":"hourly","amount":990}', 'filled');
  PERFORM pg_temp.make_job(v_br_inactive, v_now - INTERVAL '1 day', '{"type":"hourly","amount":980}');
  PERFORM pg_temp.make_job(v_br_admin, v_now - INTERVAL '1 day', '{"type":"hourly","amount":970}');
  PERFORM pg_temp.make_job(v_br_closed, v_now - INTERVAL '1 day', '{"type":"hourly","amount":960}');
  -- The only moscow job: no hourly rate.
  v_m1 := pg_temp.make_job(v_br_msk, v_now - INTERVAL '2 days', '{"type":"daily","amount":4000}');

  UPDATE public.barista_profiles SET preferred_metro_stations = ARRAY['Чернышевская', 'Площадь Восстания'] WHERE user_id = v_b01;
  UPDATE public.barista_profiles SET preferred_metro_stations = ARRAY['__any__'] WHERE user_id = v_b02;
  UPDATE public.barista_profiles SET city = 'moscow', preferred_metro_stations = ARRAY['__any__'] WHERE user_id = v_b03;
  UPDATE public.barista_profiles SET city = 'kazan', preferred_metro_stations = ARRAY['__any__'] WHERE user_id = v_b04;
  UPDATE public.barista_profiles SET profile_completeness = 29, preferred_metro_stations = ARRAY['Чернышевская'] WHERE user_id = v_b05;
  UPDATE public.barista_profiles SET preferred_metro_stations = ARRAY['Чернышевская'] WHERE user_id IN (v_b06, v_b07, v_b08, v_b09, v_b10);
  UPDATE public.barista_profiles SET is_actively_looking = false, preferred_metro_stations = ARRAY['Чернышевская'] WHERE user_id = v_b11;
  UPDATE public.users SET banned_at = v_now - INTERVAL '1 day' WHERE id = v_b09;
  UPDATE public.users SET is_active = false WHERE id = v_b10;

  INSERT INTO public.user_activity (user_id, last_seen_at)
  SELECT u, v_now - INTERVAL '1 day'
  FROM unnest(ARRAY[v_b01, v_b02, v_b03, v_b04, v_b05, v_b08, v_b09, v_b10, v_b11]) AS u;
  INSERT INTO public.user_activity (user_id, last_seen_at) VALUES
    (v_b06, v_now - INTERVAL '61 days'),
    (v_b12, v_now - INTERVAL '60 days');

  -- Station matches first (newest first), then the newest of the rest.
  v_data_stations := jsonb_build_object('kind', 'weekly_digest', 'city', 'spb',
    'jobIds', concat_ws(',', v_s1, v_s2, v_s3, v_n1, v_n2));
  v_data_city := jsonb_build_object('kind', 'weekly_digest', 'city', 'spb',
    'jobIds', concat_ws(',', v_s1, v_n1, v_s2, v_n2, v_s3));
  v_data_moscow := jsonb_build_object('kind', 'weekly_digest', 'city', 'moscow', 'jobIds', v_m1::TEXT);

  SELECT jsonb_agg(jsonb_build_object('email', u.email, 'title', r.title, 'body', r.body, 'data', r.data) ORDER BY u.email)
    INTO v_actual
  FROM app_internal.weekly_digest_recipients('barista', v_now) r
  JOIN public.users u ON u.id = r.user_id;

  v_expected := jsonb_build_array(
    jsonb_build_object('email', 't2-b01-stations@test.local', 'title', 'Смены недели', 'body', v_body_stations, 'data', v_data_stations),
    jsonb_build_object('email', 't2-b02-any@test.local', 'title', 'Смены недели', 'body', v_body_city, 'data', v_data_city),
    jsonb_build_object('email', 't2-b03-moscow@test.local', 'title', 'Смены недели', 'body', v_body_moscow, 'data', v_data_moscow),
    jsonb_build_object('email', 't2-b12-seen-60d@test.local', 'title', 'Смены недели', 'body', v_body_city, 'data', v_data_city)
  );
  ASSERT v_actual = v_expected,
    'barista digest: ' || E'\nactual:   ' || v_actual::TEXT || E'\nexpected: ' || v_expected::TEXT;
  RAISE NOTICE 'ok: barista digest (counts, stations, max rate, jobIds order, exclusions)';

  UPDATE public.feature_flags SET value = '"off"' WHERE key = 'engagement_push_mode';
  ASSERT app_internal.process_weekly_digest('barista', v_now) = 0, 'mode off: nothing is queued';
  ASSERT (SELECT count(*) FROM app_internal.engagement_pushes WHERE kind = 'weekly_digest') = 0,
    'mode off: no weekly_digest rows';

  UPDATE public.feature_flags SET value = '"on"' WHERE key = 'engagement_push_mode';
  ASSERT app_internal.process_weekly_digest('barista', v_now) = 4, 'barista run queues the 4 recipients';
  ASSERT app_internal.process_weekly_digest('barista', v_now) = 0, 'second run on the same Moscow day queues nothing';

  SELECT jsonb_agg(jsonb_build_object(
           'email', u.email, 'kind', ep.kind, 'title', ep.title, 'body', ep.body, 'data', ep.data,
           'dedupe_key', ep.dedupe_key, 'send_after', ep.send_after,
           'queued', ep.sent_at IS NULL AND ep.skipped_reason IS NULL) ORDER BY u.email)
    INTO v_actual
  FROM app_internal.engagement_pushes ep
  JOIN public.users u ON u.id = ep.user_id
  WHERE ep.kind = 'weekly_digest';

  v_expected := jsonb_build_array(
    jsonb_build_object('email', 't2-b01-stations@test.local', 'kind', 'weekly_digest', 'title', 'Смены недели',
      'body', v_body_stations, 'data', v_data_stations,
      'dedupe_key', 'wd:barista:2026-11-23:' || v_b01, 'send_after', v_now, 'queued', true),
    jsonb_build_object('email', 't2-b02-any@test.local', 'kind', 'weekly_digest', 'title', 'Смены недели',
      'body', v_body_city, 'data', v_data_city,
      'dedupe_key', 'wd:barista:2026-11-23:' || v_b02, 'send_after', v_now, 'queued', true),
    jsonb_build_object('email', 't2-b03-moscow@test.local', 'kind', 'weekly_digest', 'title', 'Смены недели',
      'body', v_body_moscow, 'data', v_data_moscow,
      'dedupe_key', 'wd:barista:2026-11-23:' || v_b03, 'send_after', v_now, 'queued', true),
    jsonb_build_object('email', 't2-b12-seen-60d@test.local', 'kind', 'weekly_digest', 'title', 'Смены недели',
      'body', v_body_city, 'data', v_data_city,
      'dedupe_key', 'wd:barista:2026-11-23:' || v_b12, 'send_after', v_now, 'queued', true)
  );
  ASSERT v_actual = v_expected,
    'process_weekly_digest barista rows: ' || E'\nactual:   ' || v_actual::TEXT || E'\nexpected: ' || v_expected::TEXT;

  -- 23:30 MSK the same day is 20:30 UTC: the dedupe key must use the Moscow date.
  ASSERT app_internal.process_weekly_digest('barista', '2026-11-23 23:30+03') = 0,
    'late evening of the same Moscow day shares the dedupe key';
  -- Next Moscow day: new dedupe keys; b12 (last seen exactly 60 days before
  -- 11:00) is now outside the 60-day window, so 3 of the 4 are queued again.
  ASSERT app_internal.process_weekly_digest('barista', '2026-11-24 00:30+03') = 3,
    'the next Moscow day gets new dedupe keys';

  UPDATE public.feature_flags SET value = '"off"' WHERE key = 'engagement_push_mode';
  RAISE NOTICE 'ok: process_weekly_digest barista (mode off, count, dedupe per Moscow day, queued rows)';
END $$;

-- ---------------------------------------------------------------------------
-- 3. business digest + process_weekly_digest('business')
-- ---------------------------------------------------------------------------
-- Section 2 data is removed first so the hand counts below depend on this
-- block only (public.users cascades to profiles, businesses, jobs, pushes).
DELETE FROM public.users WHERE email LIKE 't2-%';

DO $$
DECLARE
  v_now TIMESTAMPTZ := '2026-11-23 11:00+03';
  v_o1 UUID := test.make_user('t3-o1-chern@test.local', 'business');
  v_o2 UUID := test.make_user('t3-o2-msk-no-station@test.local', 'business');
  v_o3 UUID := test.make_user('t3-o3-pending-only@test.local', 'business');
  v_o4 UUID := test.make_user('t3-o4-empty@test.local', 'business');
  v_o5 UUID := test.make_user('t3-o5-inactive-branch@test.local', 'business');
  v_o6 UUID := test.make_user('t3-o6-admin@test.local', 'business', true);
  v_o7 UUID := test.make_user('t3-o7-banned@test.local', 'business');
  v_n01 UUID := test.make_user('t3-n01@test.local');
  v_n02 UUID := test.make_user('t3-n02@test.local');
  v_n03 UUID := test.make_user('t3-n03-any@test.local');
  v_n04 UUID := test.make_user('t3-n04-boundary@test.local');
  v_n05 UUID := test.make_user('t3-n05-8d@test.local');
  v_n06 UUID := test.make_user('t3-n06-moscow@test.local');
  v_n07 UUID := test.make_user('t3-n07-inactive-branch-station@test.local');
  v_n08 UUID := test.make_user('t3-n08-other-station@test.local');
  v_n09 UUID := test.make_user('t3-n09-admin@test.local', 'barista', true);
  v_n10 UUID := test.make_user('t3-n10-at-now@test.local');
  v_n11 UUID := test.make_user('t3-n11-stopped-looking@test.local');
  v_br_o1 UUID := pg_temp.make_branch(v_o1, 'spb', 'Чернышевская');
  v_br_o1_inactive UUID := pg_temp.make_branch(v_o1, 'spb', 'Садовая', false);
  v_br_o2 UUID := pg_temp.make_branch(v_o2, 'moscow', NULL);
  v_br_o3 UUID := pg_temp.make_branch(v_o3, 'kazan', 'Кремлёвская');
  v_br_o4 UUID := pg_temp.make_branch(v_o4, 'kazan', NULL);
  v_br_o5 UUID := pg_temp.make_branch(v_o5, 'spb', 'Чернышевская', false);
  v_br_o6 UUID := pg_temp.make_branch(v_o6, 'spb', 'Чернышевская');
  v_br_o7 UUID := pg_temp.make_branch(v_o7, 'spb', 'Чернышевская');
  v_j_open1 UUID := pg_temp.make_job(v_br_o1, v_now - INTERVAL '30 days', NULL);
  v_j_open2 UUID := pg_temp.make_job(v_br_o1, v_now - INTERVAL '2 days', NULL);
  v_j_filled UUID := pg_temp.make_job(v_br_o1, v_now - INTERVAL '2 days', NULL, 'filled');
  v_j_o3 UUID := pg_temp.make_job(v_br_o3, v_now - INTERVAL '2 days', NULL);
  v_j_o5 UUID := pg_temp.make_job(v_br_o5, v_now - INTERVAL '2 days', NULL);
  v_body_o1 TEXT := 'Новые бариста у ваших точек: 4 за неделю · 2 отклика ждут ответа';
  v_body_o2 TEXT := 'Новые бариста у ваших точек: 1 за неделю';
  v_body_o3 TEXT := '1 отклик ждёт ответа';
  v_data_o1 JSONB := '{"kind":"weekly_digest","newBaristas":"4","pendingApplications":"2"}';
  v_data_o2 JSONB := '{"kind":"weekly_digest","newBaristas":"1","pendingApplications":"0"}';
  v_data_o3 JSONB := '{"kind":"weekly_digest","newBaristas":"0","pendingApplications":"1"}';
  v_actual JSONB;
  v_expected JSONB;
BEGIN
  UPDATE public.users SET banned_at = v_now - INTERVAL '1 day' WHERE id = v_o7;

  -- visible_since is set by the trigger only, so the seed values go in with it paused.
  ALTER TABLE public.barista_profiles DISABLE TRIGGER zz_set_visible_since;
  UPDATE public.barista_profiles SET preferred_metro_stations = ARRAY['Чернышевская'], visible_since = v_now - INTERVAL '2 days' WHERE user_id = v_n01;
  UPDATE public.barista_profiles SET preferred_metro_stations = ARRAY['Чернышевская', 'Горьковская'], visible_since = v_now - INTERVAL '6 days' WHERE user_id = v_n02;
  UPDATE public.barista_profiles SET preferred_metro_stations = ARRAY['__any__'], visible_since = v_now - INTERVAL '1 day' WHERE user_id = v_n03;
  UPDATE public.barista_profiles SET preferred_metro_stations = ARRAY['Чернышевская'], visible_since = v_now - INTERVAL '7 days' WHERE user_id = v_n04;
  UPDATE public.barista_profiles SET preferred_metro_stations = ARRAY['Чернышевская'], visible_since = v_now - INTERVAL '8 days' WHERE user_id = v_n05;
  UPDATE public.barista_profiles SET city = 'moscow', preferred_metro_stations = ARRAY['Чернышевская'], visible_since = v_now - INTERVAL '1 day' WHERE user_id = v_n06;
  UPDATE public.barista_profiles SET preferred_metro_stations = ARRAY['Садовая'], visible_since = v_now - INTERVAL '1 day' WHERE user_id = v_n07;
  UPDATE public.barista_profiles SET preferred_metro_stations = ARRAY['Горьковская'], visible_since = v_now - INTERVAL '1 day' WHERE user_id = v_n08;
  UPDATE public.barista_profiles SET preferred_metro_stations = ARRAY['Чернышевская'], visible_since = v_now - INTERVAL '1 day' WHERE user_id = v_n09;
  UPDATE public.barista_profiles SET preferred_metro_stations = ARRAY['Чернышевская'], visible_since = v_now WHERE user_id = v_n10;
  UPDATE public.barista_profiles SET preferred_metro_stations = ARRAY['Чернышевская'], visible_since = v_now - INTERVAL '1 day' WHERE user_id = v_n11;
  ALTER TABLE public.barista_profiles ENABLE TRIGGER zz_set_visible_since;
  UPDATE public.barista_profiles SET is_actively_looking = false WHERE user_id = v_n11;

  INSERT INTO public.applications (job_id, barista_id, status) VALUES
    (v_j_open1, v_n01, 'pending'),
    (v_j_open2, v_n02, 'pending'),
    (v_j_filled, v_n03, 'pending'),
    (v_j_open2, v_n09, 'pending'),
    (v_j_open1, v_n04, 'accepted'),
    (v_j_o3, v_n05, 'pending'),
    (v_j_o5, v_n05, 'pending');

  SELECT jsonb_agg(jsonb_build_object('email', u.email, 'title', r.title, 'body', r.body, 'data', r.data) ORDER BY u.email)
    INTO v_actual
  FROM app_internal.weekly_digest_recipients('business', v_now) r
  JOIN public.users u ON u.id = r.user_id;

  v_expected := jsonb_build_array(
    jsonb_build_object('email', 't3-o1-chern@test.local', 'title', 'Итоги недели', 'body', v_body_o1, 'data', v_data_o1),
    jsonb_build_object('email', 't3-o2-msk-no-station@test.local', 'title', 'Итоги недели', 'body', v_body_o2, 'data', v_data_o2),
    jsonb_build_object('email', 't3-o3-pending-only@test.local', 'title', 'Итоги недели', 'body', v_body_o3, 'data', v_data_o3)
  );
  ASSERT v_actual = v_expected,
    'business digest: ' || E'\nactual:   ' || v_actual::TEXT || E'\nexpected: ' || v_expected::TEXT;
  RAISE NOTICE 'ok: business digest (new baristas by station / city, pending applications incl. admin applicant excluded, exclusions)';

  UPDATE public.feature_flags SET value = '"on"' WHERE key = 'engagement_push_mode';
  ASSERT app_internal.process_weekly_digest('business', v_now) = 3, 'business run queues the 3 recipients';
  ASSERT app_internal.process_weekly_digest('business', v_now) = 0, 'second run on the same Moscow day queues nothing';

  SELECT jsonb_agg(jsonb_build_object(
           'email', u.email, 'kind', ep.kind, 'title', ep.title, 'body', ep.body, 'data', ep.data,
           'dedupe_key', ep.dedupe_key, 'send_after', ep.send_after,
           'queued', ep.sent_at IS NULL AND ep.skipped_reason IS NULL) ORDER BY u.email)
    INTO v_actual
  FROM app_internal.engagement_pushes ep
  JOIN public.users u ON u.id = ep.user_id
  WHERE ep.kind = 'weekly_digest';

  v_expected := jsonb_build_array(
    jsonb_build_object('email', 't3-o1-chern@test.local', 'kind', 'weekly_digest', 'title', 'Итоги недели',
      'body', v_body_o1, 'data', v_data_o1,
      'dedupe_key', 'wd:business:2026-11-23:' || v_o1, 'send_after', v_now, 'queued', true),
    jsonb_build_object('email', 't3-o2-msk-no-station@test.local', 'kind', 'weekly_digest', 'title', 'Итоги недели',
      'body', v_body_o2, 'data', v_data_o2,
      'dedupe_key', 'wd:business:2026-11-23:' || v_o2, 'send_after', v_now, 'queued', true),
    jsonb_build_object('email', 't3-o3-pending-only@test.local', 'kind', 'weekly_digest', 'title', 'Итоги недели',
      'body', v_body_o3, 'data', v_data_o3,
      'dedupe_key', 'wd:business:2026-11-23:' || v_o3, 'send_after', v_now, 'queued', true)
  );
  ASSERT v_actual = v_expected,
    'process_weekly_digest business rows: ' || E'\nactual:   ' || v_actual::TEXT || E'\nexpected: ' || v_expected::TEXT;

  UPDATE public.feature_flags SET value = '"off"' WHERE key = 'engagement_push_mode';
  RAISE NOTICE 'ok: process_weekly_digest business (count, dedupe, queued rows)';
END $$;

-- ---------------------------------------------------------------------------
-- 4. invalid audience, grants, cron
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_rejected BOOLEAN := false;
BEGIN
  BEGIN
    PERFORM count(*) FROM app_internal.weekly_digest_recipients('admin', now());
  EXCEPTION WHEN invalid_parameter_value THEN
    v_rejected := true;
  END;
  ASSERT v_rejected, 'unknown audience raises 22023';

  ASSERT (
    SELECT ARRAY[
      has_function_privilege('anon', 'app_internal.weekly_digest_recipients(text,timestamptz)', 'EXECUTE'),
      has_function_privilege('authenticated', 'app_internal.weekly_digest_recipients(text,timestamptz)', 'EXECUTE'),
      has_function_privilege('service_role', 'app_internal.weekly_digest_recipients(text,timestamptz)', 'EXECUTE'),
      has_function_privilege('anon', 'app_internal.process_weekly_digest(text,timestamptz)', 'EXECUTE'),
      has_function_privilege('authenticated', 'app_internal.process_weekly_digest(text,timestamptz)', 'EXECUTE'),
      has_function_privilege('service_role', 'app_internal.process_weekly_digest(text,timestamptz)', 'EXECUTE'),
      has_function_privilege('anon', 'public.set_barista_visible_since()', 'EXECUTE'),
      has_function_privilege('authenticated', 'public.set_barista_visible_since()', 'EXECUTE')
    ]
  ) = ARRAY[false, false, true, false, false, true, false, false],
    'grants: app_internal functions for service_role only, trigger function not callable by clients';

  ASSERT (
    SELECT jsonb_agg(jsonb_build_object('name', j.jobname, 'schedule', j.schedule, 'command', j.command) ORDER BY j.jobname)
    FROM cron.job j WHERE j.jobname LIKE 'process_weekly_digest_%'
  ) = jsonb_build_array(
    jsonb_build_object('name', 'process_weekly_digest_baristas', 'schedule', '0 8 * * 1',
      'command', 'SELECT app_internal.process_weekly_digest(''barista'');'),
    jsonb_build_object('name', 'process_weekly_digest_businesses', 'schedule', '0 9 * * 1',
      'command', 'SELECT app_internal.process_weekly_digest(''business'');')
  ), 'cron: baristas Monday 08:00 UTC, businesses Monday 09:00 UTC';

  ASSERT (
    SELECT ARRAY[tgtype::TEXT, tgenabled::TEXT]
    FROM pg_trigger WHERE tgrelid = 'public.barista_profiles'::regclass AND tgname = 'zz_set_visible_since'
  ) = ARRAY['23', 'O'],
    'trigger: BEFORE INSERT OR UPDATE, FOR EACH ROW, enabled';

  RAISE NOTICE 'ok: audience check, grants, cron, trigger definition';
END $$;

ROLLBACK;

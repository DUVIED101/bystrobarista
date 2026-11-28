-- Tests for 153_profile_threshold_30.sql. Run through run.sh (fixtures +
-- migrations are applied first). One transaction, rolled back at the end.
--
-- 153 raises the profile-completeness visibility threshold from 20 % to
-- 30 % in five functions (recurring_broadcast_recipients, weekly_digest_
-- recipients, job_nearby_audience, profile_hidden_audience and the
-- set_barista_visible_since trigger) and backfills visible_since for
-- profiles that fall below 30 %. This file checks the 29/30 boundary in
-- each of the five functions and the backfill, without re-testing
-- everything already covered by 147/148/149/151.
BEGIN;

CREATE TEMP TABLE test_ids (k TEXT PRIMARY KEY, id UUID NOT NULL) ON COMMIT DROP;

CREATE FUNCTION pg_temp.tid(p_key TEXT) RETURNS UUID LANGUAGE sql STABLE
AS $$ SELECT id FROM test_ids WHERE k = p_key $$;

CREATE FUNCTION pg_temp.make_branch(p_owner UUID, p_city TEXT, p_station TEXT, p_active BOOLEAN DEFAULT true)
RETURNS UUID LANGUAGE sql
AS $$
  INSERT INTO public.branches (business_id, name, city, metro_station, is_active)
  SELECT b.id, COALESCE(p_station, p_city), p_city, p_station, p_active
  FROM public.businesses b WHERE b.owner_id = p_owner
  RETURNING id;
$$;

CREATE FUNCTION pg_temp.make_job(p_branch UUID, p_posted TIMESTAMPTZ, p_status TEXT DEFAULT 'open')
RETURNS UUID LANGUAGE sql
AS $$
  INSERT INTO public.jobs (business_id, business_owner_id, branch_id, status, posted_at, created_at)
  SELECT br.business_id, b.owner_id, br.id, p_status, p_posted, p_posted
  FROM public.branches br JOIN public.businesses b ON b.id = br.business_id
  WHERE br.id = p_branch
  RETURNING id;
$$;

-- job_nearby_audience calls this (production function from migration 075,
-- outside the 143-153 range applied by run.sh); every job below has
-- shift_details NULL, so shift_start_or_null short-circuits before it would
-- need compute_shift_start, but barista_apply_cooldown_until is always called.
CREATE TABLE test.apply_cooldowns (barista_id UUID PRIMARY KEY, until_at TIMESTAMPTZ NOT NULL);
CREATE FUNCTION app_internal.barista_apply_cooldown_until(p_barista_id UUID)
RETURNS TIMESTAMPTZ LANGUAGE sql STABLE
AS $$ SELECT c.until_at FROM test.apply_cooldowns c WHERE c.barista_id = p_barista_id $$;

-- ---------------------------------------------------------------------------
-- 1. set_barista_visible_since trigger: 29 -> hidden, 30 -> visible
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_bar UUID := test.make_user('t1-bar@test.local');
BEGIN
  UPDATE public.barista_profiles SET profile_completeness = 29 WHERE user_id = v_bar;
  ASSERT (SELECT visible_since FROM public.barista_profiles WHERE user_id = v_bar) IS NULL,
    'looking at 29 % completeness: visible_since is NULL';

  UPDATE public.barista_profiles SET profile_completeness = 30 WHERE user_id = v_bar;
  ASSERT (SELECT visible_since FROM public.barista_profiles WHERE user_id = v_bar) = now(),
    'looking at 30 % completeness: visible_since is set';

  RAISE NOTICE 'ok: set_barista_visible_since trigger (29 hidden, 30 visible)';
END $$;

-- ---------------------------------------------------------------------------
-- 2. job_nearby_audience / weekly_digest_recipients / recurring_broadcast_
--    recipients all exclude 29 % and include 30 %
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_now TIMESTAMPTZ := now();
  v_bar UUID := test.make_user('t2-bar@test.local');
  v_owner UUID := test.make_user('t2-owner@test.local', 'business');
  v_branch UUID := pg_temp.make_branch(v_owner, 'spb', 'Чернышевская');
  v_job UUID;
  v_rb UUID;
BEGIN
  UPDATE public.barista_profiles SET preferred_metro_stations = ARRAY['__any__'] WHERE user_id = v_bar;
  INSERT INTO public.user_activity (user_id, last_seen_at) VALUES (v_bar, v_now - INTERVAL '1 day');

  v_job := pg_temp.make_job(v_branch, v_now - INTERVAL '1 day');

  INSERT INTO public.recurring_broadcasts
    (name, template, city, weekdays, send_time, lookback_days, min_count, title, body, body_city)
  VALUES
    ('t153 rb', 'new_jobs_near_metro', NULL, ARRAY[1], '12:00', 3, 1, 't', '{count} {shifts} у м. {metro}', '{count} {shifts} в {city}')
  RETURNING id INTO v_rb;

  UPDATE public.barista_profiles SET profile_completeness = 29 WHERE user_id = v_bar;
  ASSERT (SELECT count(*) FROM app_internal.job_nearby_audience(v_job, v_now) a WHERE a.user_id = v_bar) = 0,
    'job_nearby_audience excludes 29 %';
  ASSERT (SELECT count(*) FROM app_internal.weekly_digest_recipients('barista', v_now) r WHERE r.user_id = v_bar) = 0,
    'weekly_digest_recipients excludes 29 %';
  ASSERT (SELECT count(*) FROM app_internal.recurring_broadcast_recipients(v_rb, v_now) r WHERE r.user_id = v_bar) = 0,
    'recurring_broadcast_recipients excludes 29 %';

  UPDATE public.barista_profiles SET profile_completeness = 30 WHERE user_id = v_bar;
  ASSERT (SELECT count(*) FROM app_internal.job_nearby_audience(v_job, v_now) a WHERE a.user_id = v_bar) = 1,
    'job_nearby_audience includes 30 %';
  ASSERT (SELECT count(*) FROM app_internal.weekly_digest_recipients('barista', v_now) r WHERE r.user_id = v_bar) = 1,
    'weekly_digest_recipients includes 30 %';
  ASSERT (SELECT count(*) FROM app_internal.recurring_broadcast_recipients(v_rb, v_now) r WHERE r.user_id = v_bar) = 1,
    'recurring_broadcast_recipients includes 30 %';

  RAISE NOTICE 'ok: job_nearby_audience, weekly_digest_recipients, recurring_broadcast_recipients (29 out, 30 in)';
END $$;

-- ---------------------------------------------------------------------------
-- 3. profile_hidden_audience: 29 in, 30 out
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_now TIMESTAMPTZ := now();
  v_bar UUID := test.make_user('t3-bar@test.local');
BEGIN
  UPDATE public.feature_flags SET value = '"on"' WHERE key = 'engagement_push_mode';
  INSERT INTO public.user_activity (user_id, last_seen_at) VALUES (v_bar, v_now - INTERVAL '1 day');

  UPDATE public.barista_profiles SET profile_completeness = 29 WHERE user_id = v_bar;
  ASSERT (SELECT count(*) FROM app_internal.profile_hidden_audience(v_now) a WHERE a.user_id = v_bar) = 1,
    'profile_hidden_audience includes 29 %';

  UPDATE public.barista_profiles SET profile_completeness = 30 WHERE user_id = v_bar;
  ASSERT (SELECT count(*) FROM app_internal.profile_hidden_audience(v_now) a WHERE a.user_id = v_bar) = 0,
    'profile_hidden_audience excludes 30 %';

  RAISE NOTICE 'ok: profile_hidden_audience (29 in, 30 out)';
END $$;

-- ---------------------------------------------------------------------------
-- 4. Backfill: re-applying 153 nulls visible_since below 30 %, leaves
--    profiles at or above 30 % untouched, and never touches updated_at.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_below UUID := test.make_user('t4-below@test.local');
  v_above UUID := test.make_user('t4-above@test.local');
  v_updated TIMESTAMPTZ := '2026-10-01 10:00+03';
BEGIN
  ALTER TABLE public.barista_profiles DISABLE TRIGGER zz_set_visible_since;
  ALTER TABLE public.barista_profiles DISABLE TRIGGER update_barista_profiles_updated_at;
  UPDATE public.barista_profiles
     SET profile_completeness = 25, visible_since = v_updated, updated_at = v_updated
   WHERE user_id = v_below;
  UPDATE public.barista_profiles
     SET profile_completeness = 40, visible_since = v_updated, updated_at = v_updated
   WHERE user_id = v_above;
  ALTER TABLE public.barista_profiles ENABLE TRIGGER update_barista_profiles_updated_at;
  ALTER TABLE public.barista_profiles ENABLE TRIGGER zz_set_visible_since;

  INSERT INTO test_ids VALUES ('t4_below', v_below), ('t4_above', v_above);

  RAISE NOTICE 'ok: backfill fixture (25 %% visible, 40 %% visible, pre-153 state simulated)';
END $$;

\ir ../../migrations/153_profile_threshold_30.sql

DO $$
BEGIN
  ASSERT (
    SELECT ARRAY[bp.visible_since, bp.updated_at]
    FROM public.barista_profiles bp WHERE bp.user_id = pg_temp.tid('t4_below')
  ) = ARRAY[NULL::TIMESTAMPTZ, '2026-10-01 10:00+03'::TIMESTAMPTZ],
    'backfill: 25 %% visible profile loses visible_since, updated_at untouched';

  ASSERT (
    SELECT ARRAY[bp.visible_since, bp.updated_at]
    FROM public.barista_profiles bp WHERE bp.user_id = pg_temp.tid('t4_above')
  ) = ARRAY['2026-10-01 10:00+03'::TIMESTAMPTZ, '2026-10-01 10:00+03'::TIMESTAMPTZ],
    'backfill: 40 %% visible profile is untouched';

  RAISE NOTICE 'ok: backfill (25 %% nulled, 40 %% kept, updated_at never touched), migration re-applies cleanly';
END $$;

-- ---------------------------------------------------------------------------
-- 5. ACLs of the five functions are unchanged by 153
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  ASSERT (
    SELECT ARRAY[
      has_function_privilege('anon', 'app_internal.recurring_broadcast_recipients(uuid,timestamptz)', 'EXECUTE'),
      has_function_privilege('authenticated', 'app_internal.recurring_broadcast_recipients(uuid,timestamptz)', 'EXECUTE'),
      has_function_privilege('service_role', 'app_internal.recurring_broadcast_recipients(uuid,timestamptz)', 'EXECUTE'),
      has_function_privilege('anon', 'app_internal.weekly_digest_recipients(text,timestamptz)', 'EXECUTE'),
      has_function_privilege('authenticated', 'app_internal.weekly_digest_recipients(text,timestamptz)', 'EXECUTE'),
      has_function_privilege('service_role', 'app_internal.weekly_digest_recipients(text,timestamptz)', 'EXECUTE'),
      has_function_privilege('anon', 'app_internal.job_nearby_audience(uuid,timestamptz)', 'EXECUTE'),
      has_function_privilege('authenticated', 'app_internal.job_nearby_audience(uuid,timestamptz)', 'EXECUTE'),
      has_function_privilege('service_role', 'app_internal.job_nearby_audience(uuid,timestamptz)', 'EXECUTE'),
      has_function_privilege('anon', 'app_internal.profile_hidden_audience(timestamptz)', 'EXECUTE'),
      has_function_privilege('authenticated', 'app_internal.profile_hidden_audience(timestamptz)', 'EXECUTE'),
      has_function_privilege('service_role', 'app_internal.profile_hidden_audience(timestamptz)', 'EXECUTE'),
      has_function_privilege('anon', 'public.set_barista_visible_since()', 'EXECUTE'),
      has_function_privilege('authenticated', 'public.set_barista_visible_since()', 'EXECUTE')
    ]
  ) = ARRAY[false, false, true, false, false, true, false, false, true, false, false, true, false, false],
    'ACLs unchanged: app_internal functions for service_role only, trigger function not client-callable';

  RAISE NOTICE 'ok: ACLs of the five functions unchanged';
END $$;

ROLLBACK;

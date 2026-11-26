-- Tests for 152_client_build.sql. Run through run.sh (fixtures + migrations
-- are applied first). One transaction, rolled back at the end.
BEGIN;

CREATE TEMP TABLE test_ids (k TEXT PRIMARY KEY, id UUID NOT NULL) ON COMMIT DROP;

CREATE FUNCTION pg_temp.tid(p_key TEXT) RETURNS UUID LANGUAGE sql STABLE
AS $$ SELECT id FROM test_ids WHERE k = p_key $$;

-- Platform + build stored for a user, as 'platform/build' with NULLs spelled out.
CREATE FUNCTION pg_temp.client(p_user UUID) RETURNS TEXT LANGUAGE sql STABLE
AS $$
  SELECT COALESCE(last_platform, 'NULL') || '/' || COALESCE(last_build::TEXT, 'NULL')
  FROM public.user_activity WHERE user_id = p_user
$$;

INSERT INTO test_ids (k, id) VALUES
  ('legacy', test.make_user('t152-legacy@test.local')),
  ('ios', test.make_user('t152-ios@test.local')),
  ('bad', test.make_user('t152-bad@test.local')),
  ('anon', test.make_user('t152-anon@test.local'));

-- ---------------------------------------------------------------------------
-- 1. Zero-arg call still resolves to the old function (no ambiguity)
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_user UUID := pg_temp.tid('legacy');
  v_msk_today DATE := (now() AT TIME ZONE 'Europe/Moscow')::date;
BEGIN
  ASSERT (SELECT array_agg(pronargdefaults ORDER BY pronargs)
            FROM pg_proc
           WHERE proname = 'touch_last_seen' AND pronamespace = 'public'::regnamespace) = ARRAY[0, 0]::smallint[],
    'both touch_last_seen signatures exist and neither has defaults';

  PERFORM test.act_as(v_user);
  PERFORM public.touch_last_seen();

  ASSERT (SELECT row(last_seen_at, last_platform, last_build)::TEXT FROM public.user_activity WHERE user_id = v_user)
         = row(now(), NULL::TEXT, NULL::INT)::TEXT,
    'zero-arg call writes last_seen_at and leaves platform/build NULL';
  ASSERT (SELECT array_agg(day) FROM public.user_activity_days WHERE user_id = v_user) = ARRAY[v_msk_today],
    'zero-arg call writes the Moscow activity day';
  RAISE NOTICE 'ok: zero-arg touch_last_seen() is unambiguous and unchanged';
END $$;

-- ---------------------------------------------------------------------------
-- 2. Two-arg call: activity row + day + platform/build; updates within the guard
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_user UUID := pg_temp.tid('ios');
  v_msk_today DATE := (now() AT TIME ZONE 'Europe/Moscow')::date;
  v_recent TIMESTAMPTZ := now() - INTERVAL '2 minutes';
BEGIN
  PERFORM test.act_as(v_user);
  PERFORM public.touch_last_seen('ios', 87);

  ASSERT (SELECT row(last_seen_at, last_platform, last_build)::TEXT FROM public.user_activity WHERE user_id = v_user)
         = row(now(), 'ios'::TEXT, 87)::TEXT,
    'first 2-arg call creates user_activity with (ios, 87)';
  ASSERT (SELECT array_agg(day) FROM public.user_activity_days WHERE user_id = v_user) = ARRAY[v_msk_today],
    '2-arg call writes the Moscow activity day';

  UPDATE public.user_activity SET last_seen_at = v_recent WHERE user_id = v_user;
  PERFORM public.touch_last_seen('ios', 88);

  ASSERT (SELECT row(last_seen_at, last_platform, last_build)::TEXT FROM public.user_activity WHERE user_id = v_user)
         = row(v_recent, 'ios'::TEXT, 88)::TEXT,
    'new build is stored while the 5-minute guard keeps last_seen_at';
  RAISE NOTICE 'ok: 2-arg call records platform/build and updates inside the guard window';
END $$;

-- ---------------------------------------------------------------------------
-- 3. Invalid platform / build -> NULL
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_user UUID := pg_temp.tid('bad');
  v_case RECORD;
BEGIN
  PERFORM test.act_as(v_user);

  PERFORM public.touch_last_seen('symbian', 87);
  ASSERT pg_temp.client(v_user) = 'NULL/87', 'unknown platform symbian is stored as NULL';

  FOR v_case IN SELECT * FROM (VALUES
    ('ios', 0, 'ios/NULL'),
    ('ios', -1, 'ios/NULL'),
    ('ios', 2000000, 'ios/NULL'),
    ('android', 1, 'android/1'),
    ('web', 1000000, 'web/1000000'),
    ('ios', NULL, 'ios/NULL')
  ) AS c(platform, build, expected)
  LOOP
    PERFORM public.touch_last_seen(v_case.platform, v_case.build);
    ASSERT pg_temp.client(v_user) = v_case.expected,
      format('(%s, %s) is stored as %s, got %s', v_case.platform, v_case.build, v_case.expected, pg_temp.client(v_user));
  END LOOP;
  RAISE NOTICE 'ok: invalid platform and out-of-range builds are stored as NULL, bounds 1 and 1000000 kept';
END $$;

-- ---------------------------------------------------------------------------
-- 4. No auth -> no rows
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  PERFORM test.act_as(NULL);
  PERFORM public.touch_last_seen('ios', 87);

  ASSERT (SELECT count(*) FROM public.user_activity WHERE user_id = pg_temp.tid('anon')) = 0
     AND (SELECT count(*) FROM public.user_activity_days WHERE user_id = pg_temp.tid('anon')) = 0
     AND (SELECT count(*) FROM public.user_activity
           WHERE user_id NOT IN (pg_temp.tid('legacy'), pg_temp.tid('ios'), pg_temp.tid('bad'))) = 0,
    'call without auth.uid() writes nothing';
  RAISE NOTICE 'ok: no auth -> no rows';
END $$;

-- ---------------------------------------------------------------------------
-- 5. Grants
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  ASSERT ARRAY[
      has_function_privilege('anon', 'public.touch_last_seen()', 'EXECUTE'),
      has_function_privilege('authenticated', 'public.touch_last_seen()', 'EXECUTE'),
      has_function_privilege('anon', 'public.touch_last_seen(text,int)', 'EXECUTE'),
      has_function_privilege('authenticated', 'public.touch_last_seen(text,int)', 'EXECUTE')
    ] = ARRAY[false, true, false, true],
    'anon cannot, authenticated can execute both signatures';
  RAISE NOTICE 'ok: grants';
END $$;

-- ---------------------------------------------------------------------------
-- 6. Flags seeded as JSON null
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  ASSERT (SELECT jsonb_object_agg(key, value) FROM public.feature_flags
           WHERE key IN ('latest_ios_build', 'min_ios_build'))
         = '{"latest_ios_build": null, "min_ios_build": null}'::jsonb,
    'latest_ios_build and min_ios_build seeded as JSON null';
  RAISE NOTICE 'ok: flags seeded as JSON null';
END $$;

-- ---------------------------------------------------------------------------
-- 7. Re-apply is idempotent and keeps admin-set flag values
-- ---------------------------------------------------------------------------
UPDATE public.feature_flags SET value = '87'::jsonb WHERE key = 'min_ios_build';
\ir ../../migrations/152_client_build.sql

DO $$
BEGIN
  ASSERT (SELECT jsonb_object_agg(key, value) FROM public.feature_flags
           WHERE key IN ('latest_ios_build', 'min_ios_build'))
         = '{"latest_ios_build": null, "min_ios_build": 87}'::jsonb,
    're-apply keeps the admin-set min_ios_build';
  ASSERT (SELECT count(*) FROM pg_proc
           WHERE proname = 'touch_last_seen' AND pronamespace = 'public'::regnamespace) = 2,
    're-apply keeps exactly two touch_last_seen signatures';
  ASSERT ARRAY[
      has_function_privilege('anon', 'public.touch_last_seen(text,int)', 'EXECUTE'),
      has_function_privilege('authenticated', 'public.touch_last_seen(text,int)', 'EXECUTE')
    ] = ARRAY[false, true],
    're-apply keeps the grants';

  PERFORM test.act_as(pg_temp.tid('ios'));
  PERFORM public.touch_last_seen();
  PERFORM public.touch_last_seen('web', 5);
  ASSERT pg_temp.client(pg_temp.tid('ios')) = 'web/5', 'both signatures still callable after re-apply';
  RAISE NOTICE 'ok: re-apply idempotent';
END $$;

ROLLBACK;

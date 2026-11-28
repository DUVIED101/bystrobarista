-- Tests for 151_profile_hidden.sql. Run through run.sh (fixtures + migrations
-- are applied first). One transaction, rolled back at the end.
--
-- Reference moment v_now = now(): the 14-day spacing reads
-- engagement_pushes.created_at, which enqueue_engagement_push stamps with the
-- session clock, so the "just queued" rows must be compared against the same
-- clock. Older history is simulated by rewriting created_at / sent_at.
BEGIN;

CREATE TEMP TABLE test_ids (k TEXT PRIMARY KEY, id UUID NOT NULL) ON COMMIT DROP;

CREATE FUNCTION pg_temp.tid(p_key TEXT) RETURNS UUID LANGUAGE sql STABLE
AS $$ SELECT id FROM test_ids WHERE k = p_key $$;

-- Audience as [{email, attempt, title, body, data}] ordered by email.
CREATE FUNCTION pg_temp.audience(p_now TIMESTAMPTZ) RETURNS JSONB LANGUAGE sql STABLE
AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object('email', u.email, 'attempt', a.attempt, 'title', a.title, 'body', a.body, 'data', a.data)
                            ORDER BY u.email), '[]'::jsonb)
  FROM app_internal.profile_hidden_audience(p_now) a
  JOIN public.users u ON u.id = a.user_id
$$;

CREATE FUNCTION pg_temp.exp_row(p_key TEXT, p_attempt INT, p_pct INT) RETURNS JSONB LANGUAGE sql STABLE
AS $$
  SELECT jsonb_build_object(
    'email', 'ph-' || p_key || '@test.local',
    'attempt', p_attempt,
    'title', 'Кофейни вас не видят',
    'body', 'Профиль заполнен на ' || p_pct || ' %. Добавьте фото и станции метро, чтобы попасть в поиск',
    'data', jsonb_build_object('kind', 'profile_hidden', 'completeness', p_pct::TEXT))
$$;

-- Queued profile_hidden rows as [{email, dedupe_key, send_after, queued}] ordered by dedupe_key.
CREATE FUNCTION pg_temp.pushes() RETURNS JSONB LANGUAGE sql STABLE
AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object('email', u.email, 'dedupe_key', ep.dedupe_key, 'send_after', ep.send_after,
                                               'queued', ep.sent_at IS NULL AND ep.skipped_reason IS NULL)
                            ORDER BY ep.dedupe_key), '[]'::jsonb)
  FROM app_internal.engagement_pushes ep
  JOIN public.users u ON u.id = ep.user_id
  WHERE ep.kind = 'profile_hidden'
$$;

-- ---------------------------------------------------------------------------
-- 1. Fixture data
-- ---------------------------------------------------------------------------
-- All baristas looking with completeness 29 and seen 1 day ago unless noted:
--   included: a, e seen 89 d, j completeness 0, k completeness NULL
--   excluded: b completeness 30, c not looking, d seen 91 d, f banned,
--             g inactive, h admin, i never seen
DO $$
DECLARE
  v_now TIMESTAMPTZ := now();
  v_u UUID;
  k TEXT;
BEGIN
  UPDATE public.feature_flags SET value = '"on"' WHERE key = 'engagement_push_mode';

  FOREACH k IN ARRAY ARRAY['a', 'b', 'c', 'd', 'e', 'f', 'g', 'i', 'j', 'k'] LOOP
    v_u := test.make_user('ph-' || k || '@test.local', 'barista');
    INSERT INTO test_ids VALUES ('bar_' || k, v_u);
  END LOOP;
  v_u := test.make_user('ph-h@test.local', 'barista', true);
  INSERT INTO test_ids VALUES ('bar_h', v_u);

  UPDATE public.barista_profiles SET profile_completeness = 29
   WHERE user_id IN (SELECT t.id FROM test_ids t WHERE t.k LIKE 'bar_%');
  UPDATE public.barista_profiles SET profile_completeness = 30 WHERE user_id = pg_temp.tid('bar_b');
  UPDATE public.barista_profiles SET is_actively_looking = false WHERE user_id = pg_temp.tid('bar_c');
  UPDATE public.barista_profiles SET profile_completeness = 0 WHERE user_id = pg_temp.tid('bar_j');
  UPDATE public.barista_profiles SET profile_completeness = NULL WHERE user_id = pg_temp.tid('bar_k');
  UPDATE public.users SET banned_at = v_now - INTERVAL '1 day' WHERE id = pg_temp.tid('bar_f');
  UPDATE public.users SET is_active = false WHERE id = pg_temp.tid('bar_g');

  INSERT INTO public.user_activity (user_id, last_seen_at)
  SELECT pg_temp.tid('bar_' || x), v_now - INTERVAL '1 day'
  FROM unnest(ARRAY['a', 'b', 'c', 'f', 'g', 'h', 'j', 'k']) AS x;
  INSERT INTO public.user_activity (user_id, last_seen_at) VALUES
    (pg_temp.tid('bar_d'), v_now - INTERVAL '91 days'),
    (pg_temp.tid('bar_e'), v_now - INTERVAL '89 days');

  -- A push of another kind must not count towards the three attempts.
  PERFORM app_internal.enqueue_engagement_push(pg_temp.tid('bar_a'), 'weekly_digest', 't', 'b', '{}', 'wd:test:a', v_now);
END $$;

-- ---------------------------------------------------------------------------
-- 2. Audience + process_profile_hidden, attempts 1..3
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_now TIMESTAMPTZ := now();
  v_a UUID := pg_temp.tid('bar_a');
  v_actual JSONB;
  v_expected JSONB;
BEGIN
  v_expected := jsonb_build_array(
    pg_temp.exp_row('a', 1, 29), pg_temp.exp_row('e', 1, 29), pg_temp.exp_row('j', 1, 0), pg_temp.exp_row('k', 1, 0));
  v_actual := pg_temp.audience(v_now);
  ASSERT v_actual = v_expected,
    'first audience: ' || E'\nactual:   ' || v_actual::TEXT || E'\nexpected: ' || v_expected::TEXT;
  RAISE NOTICE 'ok: audience (completeness 29 / 0 / NULL in, 30 out; not looking, 91 d, banned, inactive, admin, never seen out)';

  UPDATE public.feature_flags SET value = '"off"' WHERE key = 'engagement_push_mode';
  ASSERT app_internal.process_profile_hidden(v_now) = 0, 'mode off: nothing is queued';
  ASSERT pg_temp.pushes() = '[]'::jsonb, 'mode off: no profile_hidden rows';
  UPDATE public.feature_flags SET value = '"on"' WHERE key = 'engagement_push_mode';

  ASSERT app_internal.process_profile_hidden(v_now) = 4, 'first run queues the 4 recipients';
  v_expected := (
    SELECT jsonb_agg(jsonb_build_object('email', 'ph-' || x || '@test.local', 'dedupe_key', 'ph:' || pg_temp.tid('bar_' || x) || ':1',
                                        'send_after', v_now, 'queued', true) ORDER BY 'ph:' || pg_temp.tid('bar_' || x) || ':1')
    FROM unnest(ARRAY['a', 'e', 'j', 'k']) AS x);
  v_actual := pg_temp.pushes();
  ASSERT v_actual = v_expected,
    'queued rows: ' || E'\nactual:   ' || v_actual::TEXT || E'\nexpected: ' || v_expected::TEXT;

  ASSERT pg_temp.audience(v_now) = '[]'::jsonb, 'nobody is eligible right after the first push';
  ASSERT app_internal.process_profile_hidden(v_now + INTERVAL '6 days') = 0, 'a run the same week queues nothing';
  ASSERT app_internal.process_profile_hidden(v_now + INTERVAL '14 days') = 0, 'exactly 14 days later is still too early';
  -- e (seen 89 days before v_now) is past the 90-day window by then.
  ASSERT pg_temp.audience(v_now + INTERVAL '14 days 1 second')
       = jsonb_build_array(pg_temp.exp_row('a', 2, 29), pg_temp.exp_row('j', 2, 0), pg_temp.exp_row('k', 2, 0)),
    'past 14 days the still-active recipients are due for attempt 2';

  -- a's first push is 15 days old and was skipped (dry_run): it still counts.
  UPDATE app_internal.engagement_pushes
     SET created_at = v_now - INTERVAL '15 days', skipped_reason = 'dry_run'
   WHERE dedupe_key = 'ph:' || v_a || ':1';
  ASSERT pg_temp.audience(v_now) = jsonb_build_array(pg_temp.exp_row('a', 2, 29)), 'a is due for attempt 2 (a skipped attempt counts)';
  ASSERT app_internal.process_profile_hidden(v_now) = 1, 'second run queues attempt 2 for a only';
  ASSERT (SELECT ep.send_after FROM app_internal.engagement_pushes ep WHERE ep.dedupe_key = 'ph:' || v_a || ':2') = v_now,
    'attempt 2 row carries dedupe_key ph:<user>:2';

  UPDATE app_internal.engagement_pushes
     SET created_at = v_now - INTERVAL '15 days', sent_at = v_now - INTERVAL '15 days'
   WHERE dedupe_key = 'ph:' || v_a || ':2';
  ASSERT pg_temp.audience(v_now) = jsonb_build_array(pg_temp.exp_row('a', 3, 29)), 'a is due for attempt 3 (a sent attempt counts)';
  ASSERT app_internal.process_profile_hidden(v_now) = 1, 'third run queues attempt 3 for a only';

  UPDATE app_internal.engagement_pushes
     SET created_at = v_now - INTERVAL '15 days'
   WHERE dedupe_key = 'ph:' || v_a || ':3';
  ASSERT pg_temp.audience(v_now) = '[]'::jsonb, 'after 3 attempts a is never nagged again';
  ASSERT app_internal.process_profile_hidden(v_now) = 0, 'nothing more to queue';

  ASSERT (SELECT array_agg(ep.dedupe_key ORDER BY ep.dedupe_key) FROM app_internal.engagement_pushes ep WHERE ep.user_id = v_a)
       = ARRAY['ph:' || v_a || ':1', 'ph:' || v_a || ':2', 'ph:' || v_a || ':3', 'wd:test:a'],
    'a ends with exactly three profile_hidden rows plus the unrelated digest row';

  -- Completing the profile stops the sequence even when an attempt is due.
  UPDATE public.barista_profiles SET profile_completeness = 30 WHERE user_id = pg_temp.tid('bar_j');
  ASSERT pg_temp.audience(v_now + INTERVAL '15 days') = jsonb_build_array(pg_temp.exp_row('k', 2, 0)),
    'j reached 30 % and leaves the audience; only k is due for attempt 2';

  RAISE NOTICE 'ok: process_profile_hidden (mode off, dedupe ph:<user>:<attempt>, 14-day spacing, 3 attempts max)';
END $$;

-- ---------------------------------------------------------------------------
-- 3. Grants, cron
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  ASSERT (
    SELECT ARRAY[
      has_function_privilege('anon', 'app_internal.profile_hidden_audience(timestamptz)', 'EXECUTE'),
      has_function_privilege('authenticated', 'app_internal.profile_hidden_audience(timestamptz)', 'EXECUTE'),
      has_function_privilege('service_role', 'app_internal.profile_hidden_audience(timestamptz)', 'EXECUTE'),
      has_function_privilege('anon', 'app_internal.process_profile_hidden(timestamptz)', 'EXECUTE'),
      has_function_privilege('authenticated', 'app_internal.process_profile_hidden(timestamptz)', 'EXECUTE'),
      has_function_privilege('service_role', 'app_internal.process_profile_hidden(timestamptz)', 'EXECUTE')
    ]
  ) = ARRAY[false, false, true, false, false, true],
    'grants: app_internal functions for service_role only';

  ASSERT (
    SELECT jsonb_build_object('schedule', j.schedule, 'command', j.command)
    FROM cron.job j WHERE j.jobname = 'process_profile_hidden'
  ) = jsonb_build_object('schedule', '0 9 * * *', 'command', 'SELECT app_internal.process_profile_hidden();'),
    'cron: process_profile_hidden daily at 09:00 UTC (12:00 MSK)';

  RAISE NOTICE 'ok: grants, cron';
END $$;

ROLLBACK;

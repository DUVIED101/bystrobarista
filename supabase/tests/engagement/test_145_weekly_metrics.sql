-- Tests for 145_weekly_metrics.sql. Run through run.sh (fixtures + migrations
-- are applied first). Seeded week: Monday 2026-11-16 .. Sunday 2026-11-22 MSK.
BEGIN;

CREATE TEMP TABLE test_ids (k TEXT PRIMARY KEY, id UUID NOT NULL) ON COMMIT DROP;

-- ---------------------------------------------------------------------------
-- 1. responded_at trigger
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_biz UUID := test.make_user('t1-biz@test.local', 'business');
  v_bar UUID := test.make_user('t1-bar@test.local', 'barista');
  v_bar2 UUID := test.make_user('t1-bar2@test.local', 'barista');
  v_bar3 UUID := test.make_user('t1-bar3@test.local', 'barista');
  v_bar4 UUID := test.make_user('t1-bar4@test.local', 'barista');
  v_preset TIMESTAMPTZ := '2026-01-01 12:00+03';
  v_backfill_updated TIMESTAMPTZ := '2026-10-01 10:00+03';
  v_backfill_created TIMESTAMPTZ := '2026-10-02 10:00+03';
  v_business_id UUID;
  v_branch UUID;
  v_job UUID;
  v_app UUID;
  v_app_preset UUID;
  v_app_pending UUID;
  v_app_backfill UUID;
  v_offer UUID;
  v_offer_preset UUID;
  v_offer_backfill UUID;
BEGIN
  SELECT id INTO v_business_id FROM public.businesses WHERE owner_id = v_biz;
  INSERT INTO public.branches (business_id) VALUES (v_business_id) RETURNING id INTO v_branch;
  INSERT INTO public.jobs (business_id, business_owner_id, branch_id)
  VALUES (v_business_id, v_biz, v_branch) RETURNING id INTO v_job;

  INSERT INTO public.applications (job_id, barista_id) VALUES (v_job, v_bar) RETURNING id INTO v_app;
  UPDATE public.applications SET status = 'accepted' WHERE id = v_app;
  ASSERT (SELECT responded_at FROM public.applications WHERE id = v_app) = now(),
    'applications: pending -> accepted sets responded_at';

  INSERT INTO public.applications (job_id, barista_id, responded_at)
  VALUES (v_job, v_bar2, v_preset) RETURNING id INTO v_app_preset;
  UPDATE public.applications SET status = 'rejected' WHERE id = v_app_preset;
  ASSERT (SELECT responded_at FROM public.applications WHERE id = v_app_preset) = v_preset,
    'applications: preset responded_at is kept';

  INSERT INTO public.applications (job_id, barista_id) VALUES (v_job, v_bar3) RETURNING id INTO v_app_pending;
  UPDATE public.applications SET status = 'pending', cover_letter = 'x' WHERE id = v_app_pending;
  ASSERT (SELECT responded_at FROM public.applications WHERE id = v_app_pending) IS NULL,
    'applications: pending -> pending leaves responded_at NULL';

  INSERT INTO public.job_offers (business_owner_id, barista_id, job_id) VALUES (v_biz, v_bar, v_job) RETURNING id INTO v_offer;
  UPDATE public.job_offers SET status = 'declined' WHERE id = v_offer;
  ASSERT (SELECT responded_at FROM public.job_offers WHERE id = v_offer) = now(),
    'job_offers: pending -> declined sets responded_at';

  INSERT INTO public.job_offers (business_owner_id, barista_id, job_id, responded_at)
  VALUES (v_biz, v_bar2, v_job, v_preset) RETURNING id INTO v_offer_preset;
  UPDATE public.job_offers SET status = 'accepted' WHERE id = v_offer_preset;
  ASSERT (SELECT responded_at FROM public.job_offers WHERE id = v_offer_preset) = v_preset,
    'job_offers: preset responded_at is kept';

  -- Pre-existing rows that left pending before the trigger existed.
  INSERT INTO public.applications (job_id, barista_id, status, updated_at)
  VALUES (v_job, v_bar4, 'accepted', v_backfill_updated) RETURNING id INTO v_app_backfill;
  INSERT INTO public.job_offers (business_owner_id, barista_id, job_id, status, created_at)
  VALUES (v_biz, v_bar3, v_job, 'expired', v_backfill_created) RETURNING id INTO v_offer_backfill;
  INSERT INTO test_ids VALUES ('app_backfill', v_app_backfill), ('offer_backfill', v_offer_backfill);

  RAISE NOTICE 'ok: responded_at trigger on applications and job_offers';
END $$;

-- Re-applying the migration (idempotent) runs the backfill again.
\ir ../../migrations/145_weekly_metrics.sql

DO $$
DECLARE
  v_backfill_updated TIMESTAMPTZ := '2026-10-01 10:00+03';
  v_backfill_created TIMESTAMPTZ := '2026-10-02 10:00+03';
BEGIN
  ASSERT (
    SELECT ARRAY[a.responded_at, a.updated_at]
    FROM public.applications a
    WHERE a.id = (SELECT id FROM test_ids WHERE k = 'app_backfill')
  ) = ARRAY[v_backfill_updated, v_backfill_updated],
    'applications backfill: responded_at = updated_at, updated_at untouched';

  ASSERT (
    SELECT o.responded_at FROM public.job_offers o
    WHERE o.id = (SELECT id FROM test_ids WHERE k = 'offer_backfill')
  ) = v_backfill_created,
    'job_offers backfill: responded_at = created_at';

  RAISE NOTICE 'ok: responded_at backfill, migration re-applies cleanly';
END $$;

-- ---------------------------------------------------------------------------
-- 2. touch_last_seen writes user_activity_days
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_user UUID := test.make_user('t2-user@test.local', 'barista');
  v_today_msk DATE := (now() AT TIME ZONE 'Europe/Moscow')::date;
  v_days_before BIGINT;
BEGIN
  PERFORM test.act_as(v_user);
  PERFORM public.touch_last_seen();
  ASSERT (SELECT array_agg(d.day) FROM public.user_activity_days d WHERE d.user_id = v_user) = ARRAY[v_today_msk],
    'touch_last_seen: one row for the Moscow date';
  ASSERT (SELECT a.last_seen_at FROM public.user_activity a WHERE a.user_id = v_user) = now(),
    'touch_last_seen: user_activity row created';

  PERFORM public.touch_last_seen();
  ASSERT (SELECT count(*) FROM public.user_activity_days d WHERE d.user_id = v_user) = 1,
    'touch_last_seen: second call the same day adds no row';

  UPDATE public.user_activity SET last_seen_at = now() - INTERVAL '1 minute' WHERE user_id = v_user;
  PERFORM public.touch_last_seen();
  ASSERT (SELECT a.last_seen_at FROM public.user_activity a WHERE a.user_id = v_user) = now() - INTERVAL '1 minute',
    'touch_last_seen: 5-minute guard keeps a recent last_seen_at';

  UPDATE public.user_activity SET last_seen_at = now() - INTERVAL '10 minutes' WHERE user_id = v_user;
  PERFORM public.touch_last_seen();
  ASSERT (SELECT a.last_seen_at FROM public.user_activity a WHERE a.user_id = v_user) = now(),
    'touch_last_seen: stale last_seen_at is refreshed';

  SELECT count(*) INTO v_days_before FROM public.user_activity_days;
  PERFORM test.act_as(NULL);
  PERFORM public.touch_last_seen();
  ASSERT (SELECT count(*) FROM public.user_activity_days) = v_days_before,
    'touch_last_seen: no-op without auth.uid()';

  RAISE NOTICE 'ok: touch_last_seen';
END $$;

-- ---------------------------------------------------------------------------
-- 3. user_last_seen / admin_last_seen (all traces in October, away from the
--    weeks seeded below)
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_none UUID := test.make_user('t3-none@test.local', 'barista');
  v_session_wins UUID := test.make_user('t3-session@test.local', 'barista');
  v_activity_wins UUID := test.make_user('t3-activity@test.local', 'business');
  v_token_only UUID := test.make_user('t3-token@test.local', 'barista');
  v_session_ts TIMESTAMPTZ := '2026-10-14 07:00+00';
  v_activity_ts TIMESTAMPTZ := '2026-10-20 10:00+03';
  v_token_ts TIMESTAMPTZ := '2026-10-05 10:00+03';
  v_ids UUID[] := ARRAY[v_none, v_session_wins, v_activity_wins, v_token_only];
  v_expected TIMESTAMPTZ[] := ARRAY[NULL, v_session_ts, v_activity_ts, v_token_ts];
BEGIN
  INSERT INTO public.user_activity (user_id, last_seen_at) VALUES
    (v_session_wins, '2026-10-10 10:00+03'),
    (v_activity_wins, v_activity_ts);
  INSERT INTO public.device_tokens (user_id, device_token, environment, last_seen_at) VALUES
    (v_session_wins, 'tok-1', 'production', '2026-10-12 10:00+03'),
    (v_activity_wins, 'tok-2', 'production', '2026-10-12 10:00+03'),
    (v_token_only, 'tok-3', 'production', v_token_ts);
  INSERT INTO auth.sessions (user_id, refreshed_at) VALUES
    (v_session_wins, '2026-10-01 00:00'),
    (v_session_wins, (v_session_ts AT TIME ZONE 'UTC')),
    (v_activity_wins, '2026-10-01 00:00');

  ASSERT (
    SELECT array_agg(app_internal.user_last_seen(x.id) ORDER BY x.ord)
    FROM unnest(v_ids) WITH ORDINALITY AS x (id, ord)
  ) = v_expected,
    'user_last_seen: GREATEST over user_activity, device_tokens, auth.sessions; NULL without traces';

  ASSERT (
    SELECT array_agg(a.last_seen_at ORDER BY x.ord)
    FROM unnest(v_ids) WITH ORDINALITY AS x (id, ord)
    JOIN public.admin_last_seen(v_ids) a ON a.id = x.id
  ) = v_expected,
    'admin_last_seen: same values as user_last_seen';

  RAISE NOTICE 'ok: user_last_seen / admin_last_seen';
END $$;

-- ---------------------------------------------------------------------------
-- 4. compute_weekly_metrics for the week of Monday 2026-11-16 MSK, and the
--    approximate fallback for the week of 2026-11-09
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_bar1 UUID := test.make_user('t4-bar1@test.local', 'barista', false, '2026-11-01 12:00+03');
  v_bar2 UUID := test.make_user('t4-bar2@test.local', 'barista', false, '2026-11-01 12:00+03');
  v_biz1 UUID := test.make_user('t4-biz1@test.local', 'business', false, '2026-11-02 12:00+03');
  v_adm UUID := test.make_user('t4-adm@test.local', 'business', true, '2026-11-03 12:00+03');
  v_adm_b UUID := test.make_user('t4-adm-b@test.local', 'barista', true, '2026-11-03 12:00+03');
  v_bar3 UUID := test.make_user('t4-bar3@test.local', 'barista', false, '2026-11-18 15:00+03');
  v_bar_edge UUID := test.make_user('t4-bar-edge@test.local', 'barista', false, '2026-11-16 00:00:00+03');
  v_bar_before UUID := test.make_user('t4-bar-before@test.local', 'barista', false, '2026-11-15 23:59:59+03');
  v_biz2 UUID := test.make_user('t4-biz2@test.local', 'business', false, '2026-11-20 10:00+03');
  v_biz_end UUID := test.make_user('t4-biz-end@test.local', 'business', false, '2026-11-23 00:00:00+03');
  v_adm_new UUID := test.make_user('t4-adm-new@test.local', 'barista', true, '2026-11-19 12:00+03');
  v_biz1_id UUID;
  v_adm_id UUID;
  v_br1 UUID;
  v_br_adm UUID;
  v_j1 UUID;
  v_j2 UUID;
  v_j_adm UUID;
  v_j_old UUID;
  v_j_old2 UUID;
  v_j_end UUID;
  v_pushes_present BOOLEAN := to_regclass('app_internal.engagement_pushes') IS NOT NULL;
  v_expected_pushes JSONB := CASE WHEN to_regclass('app_internal.engagement_pushes') IS NOT NULL
    THEN '{"weekly_digest": 2, "new_job_nearby": 1}'::jsonb ELSE '{}'::jsonb END;
  v_actual JSONB;
BEGIN
  SELECT id INTO v_biz1_id FROM public.businesses WHERE owner_id = v_biz1;
  SELECT id INTO v_adm_id FROM public.businesses WHERE owner_id = v_adm;
  INSERT INTO public.branches (business_id) VALUES (v_biz1_id) RETURNING id INTO v_br1;
  INSERT INTO public.branches (business_id) VALUES (v_adm_id) RETURNING id INTO v_br_adm;

  INSERT INTO public.jobs (business_id, business_owner_id, branch_id, created_at)
  VALUES (v_biz1_id, v_biz1, v_br1, '2026-11-16 09:00+03') RETURNING id INTO v_j1;
  INSERT INTO public.jobs (business_id, business_owner_id, branch_id, created_at)
  VALUES (v_biz1_id, v_biz1, v_br1, '2026-11-20 12:00+03') RETURNING id INTO v_j2;
  INSERT INTO public.jobs (business_id, business_owner_id, branch_id, created_at)
  VALUES (v_adm_id, v_adm, v_br_adm, '2026-11-18 12:00+03') RETURNING id INTO v_j_adm;
  INSERT INTO public.jobs (business_id, business_owner_id, branch_id, created_at)
  VALUES (v_biz1_id, v_biz1, v_br1, '2026-11-10 12:00+03') RETURNING id INTO v_j_old;
  INSERT INTO public.jobs (business_id, business_owner_id, branch_id, created_at)
  VALUES (v_biz1_id, v_biz1, v_br1, '2026-11-05 12:00+03') RETURNING id INTO v_j_old2;
  INSERT INTO public.jobs (business_id, business_owner_id, branch_id, created_at)
  VALUES (v_biz1_id, v_biz1, v_br1, '2026-11-23 00:00:00+03') RETURNING id INTO v_j_end;

  -- Activity days: bar1 twice, bar2 on Sunday, biz1, admin (excluded),
  -- bar3 / bar_before outside the week (and outside 2026-11-09..15).
  INSERT INTO public.user_activity_days (user_id, day) VALUES
    (v_bar1, '2026-11-16'), (v_bar1, '2026-11-18'), (v_bar2, '2026-11-22'),
    (v_biz1, '2026-11-19'), (v_adm, '2026-11-17'),
    (v_bar3, '2026-11-23'), (v_bar_before, '2026-11-08');

  -- Fallback traces for the week of 2026-11-09: bar1 via user_activity,
  -- bar2 via device token + session, biz1 later, admin excluded.
  INSERT INTO public.user_activity (user_id, last_seen_at) VALUES
    (v_bar1, '2026-11-10 10:00+03'), (v_biz1, '2026-11-19 10:00+03'), (v_adm, '2026-11-11 10:00+03');
  INSERT INTO public.device_tokens (user_id, device_token, environment, last_seen_at)
  VALUES (v_bar2, 'tok-t4', 'production', '2026-11-12 10:00+03');
  INSERT INTO auth.sessions (user_id, refreshed_at) VALUES (v_bar2, '2026-11-14 07:00');

  -- Applications: latencies 10h / 50h / 100h for the three responses.
  INSERT INTO public.applications (job_id, barista_id, status, created_at, responded_at, completed_at) VALUES
    (v_j1, v_bar1, 'accepted', '2026-11-16 10:00+03', '2026-11-16 20:00+03', NULL),
    (v_j1, v_bar2, 'rejected', '2026-11-17 10:00+03', '2026-11-19 12:00+03', NULL),
    (v_j2, v_bar1, 'under_review', '2026-11-17 08:00+03', '2026-11-21 12:00+03', NULL),
    (v_j_old, v_bar2, 'pending', '2026-11-18 10:00+03', NULL, NULL),
    (v_j_old, v_bar1, 'withdrawn', '2026-11-19 10:00+03', '2026-11-19 11:00+03', NULL),
    (v_j2, v_bar2, 'accepted', '2026-11-22 23:00+03', '2026-11-23 00:30+03', NULL),
    (v_j_old2, v_bar1, 'accepted', '2026-11-13 10:00+03', '2026-11-14 10:00+03', '2026-11-20 18:00+03'),
    (v_j_old2, v_bar2, 'accepted', '2026-11-06 10:00+03', '2026-11-07 10:00+03', '2026-11-23 01:00+03'),
    (v_j1, v_adm_b, 'accepted', '2026-11-17 10:00+03', '2026-11-17 12:00+03', '2026-11-18 10:00+03'),
    (v_j_adm, v_bar2, 'accepted', '2026-11-18 13:00+03', '2026-11-18 14:00+03', NULL);

  -- Shadow of an accepted offer (respond_to_job_offer creates it): counted on
  -- the offer side only. Would otherwise add an application, a 0h response and
  -- a second closed shift.
  INSERT INTO public.applications (job_id, barista_id, status, created_via_offer, created_at, responded_at)
  VALUES (v_j2, v_bar3, 'accepted', true, '2026-11-19 10:00+03', '2026-11-19 10:00+03');

  INSERT INTO public.job_offers (business_owner_id, barista_id, job_id, status, created_at, responded_at) VALUES
    (v_biz1, v_bar1, v_j1, 'pending', '2026-11-16 10:00+03', NULL),
    (v_biz1, v_bar2, v_j2, 'accepted', '2026-11-17 10:00+03', '2026-11-18 10:00+03'),
    (v_biz1, v_bar1, v_j_old, 'declined', '2026-11-10 10:00+03', '2026-11-19 10:00+03'),
    (v_biz1, v_bar2, v_j_old, 'cancelled', '2026-11-18 10:00+03', '2026-11-18 11:00+03'),
    (v_biz1, v_bar1, v_j_old2, 'expired', '2026-11-12 10:00+03', '2026-11-20 10:00+03'),
    (v_biz1, v_bar3, v_j2, 'accepted', '2026-11-19 09:00+03', '2026-11-19 10:00+03'),
    (v_adm, v_bar1, v_j_adm, 'accepted', '2026-11-17 10:00+03', '2026-11-17 11:00+03'),
    (v_biz1, v_adm_b, v_j1, 'accepted', '2026-11-17 10:00+03', '2026-11-17 11:00+03');

  IF v_pushes_present THEN
    EXECUTE $q$
      INSERT INTO app_internal.engagement_pushes
        (user_id, kind, title, body, data, dedupe_key, send_after, sent_at, skipped_reason, created_at)
      VALUES
        ($1, 'weekly_digest', 't', 'b', '{}', 't4-push-1', '2026-11-16 11:00+03', '2026-11-16 11:00+03', NULL, '2026-11-16 10:00+03'),
        ($1, 'weekly_digest', 't', 'b', '{}', 't4-push-2', '2026-11-22 23:00+03', '2026-11-22 23:00+03', NULL, '2026-11-22 22:00+03'),
        ($2, 'new_job_nearby', 't', 'b', '{}', 't4-push-3', '2026-11-18 12:00+03', '2026-11-18 12:00+03', NULL, '2026-11-18 12:00+03'),
        ($1, 'weekly_digest', 't', 'b', '{}', 't4-push-4', '2026-11-24 11:00+03', '2026-11-24 11:00+03', NULL, '2026-11-24 10:00+03'),
        ($1, 'application_reminder', 't', 'b', '{}', 't4-push-5', '2026-11-18 12:00+03', NULL, 'dry_run', '2026-11-18 12:00+03'),
        ($3, 'weekly_digest', 't', 'b', '{}', 't4-push-6', '2026-11-18 12:00+03', '2026-11-18 12:00+03', NULL, '2026-11-18 12:00+03')
    $q$ USING v_bar1, v_bar2, v_adm;
  END IF;

  v_actual := app_internal.compute_weekly_metrics('2026-11-16');
  ASSERT v_actual = jsonb_build_object(
    'active_baristas', 2,
    'active_businesses', 1,
    'active_approximate', false,
    'new_baristas', 2,
    'new_businesses', 1,
    'new_jobs', 2,
    'applications', 6,
    'offers', 4,
    'application_responses', 3,
    'application_responses_within_72h_pct', 66.7,
    'application_response_median_hours', 50.0,
    'offer_responses', 3,
    'shifts_closed', 3,
    'shifts_completed', 1,
    'pushes_sent', v_expected_pushes
  ), format('compute_weekly_metrics(2026-11-16): %s', v_actual);

  v_actual := app_internal.compute_weekly_metrics('2026-11-09');
  ASSERT v_actual = jsonb_build_object(
    'active_baristas', 2,
    'active_businesses', 0,
    'active_approximate', true,
    'new_baristas', 1,
    'new_businesses', 0,
    'new_jobs', 1,
    'applications', 1,
    'offers', 2,
    'application_responses', 1,
    'application_responses_within_72h_pct', 100.0,
    'application_response_median_hours', 24.0,
    'offer_responses', 0,
    'shifts_closed', 1,
    'shifts_completed', 0,
    'pushes_sent', '{}'::jsonb
  ), format('compute_weekly_metrics(2026-11-09, approximate): %s', v_actual);

  v_actual := app_internal.compute_weekly_metrics('2026-08-03');
  ASSERT v_actual = jsonb_build_object(
    'active_baristas', 0,
    'active_businesses', 0,
    'active_approximate', true,
    'new_baristas', 0,
    'new_businesses', 0,
    'new_jobs', 0,
    'applications', 0,
    'offers', 0,
    'application_responses', 0,
    'application_responses_within_72h_pct', NULL,
    'application_response_median_hours', NULL,
    'offer_responses', 0,
    'shifts_closed', 0,
    'shifts_completed', 0,
    'pushes_sent', '{}'::jsonb
  ), format('compute_weekly_metrics(empty week): %s', v_actual);

  RAISE NOTICE 'ok: compute_weekly_metrics (pushes table present: %)', v_pushes_present;
END $$;

-- ---------------------------------------------------------------------------
-- 5. admin_weekly_metrics
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_admin UUID := test.make_user('t5-admin@test.local', 'business', true);
  v_user UUID := test.make_user('t5-user@test.local', 'barista');
  v_current DATE := date_trunc('week', now() AT TIME ZONE 'Europe/Moscow')::date;
  v_stored_at TIMESTAMPTZ := '2026-01-01 00:00+03';
  v_denied BOOLEAN := false;
  v_first JSONB;
BEGIN
  INSERT INTO public.weekly_metrics (week_start, metrics, computed_at)
  VALUES (v_current - 7, '{"stored": true}', v_stored_at);

  PERFORM test.act_as(v_user);
  BEGIN
    PERFORM count(*) FROM public.admin_weekly_metrics(3);
  EXCEPTION WHEN insufficient_privilege THEN
    v_denied := true;
  END;
  ASSERT v_denied, 'admin_weekly_metrics: non-admin gets 42501';

  PERFORM test.act_as(v_admin);
  ASSERT (
    SELECT jsonb_agg(jsonb_build_object(
      'week_start', m.week_start, 'week_end', m.week_end, 'is_current', m.is_current,
      'computed_at', m.computed_at, 'stored', m.metrics = '{"stored": true}'::jsonb))
    FROM public.admin_weekly_metrics(3) m
  ) = jsonb_build_array(
    jsonb_build_object('week_start', v_current, 'week_end', v_current + 6, 'is_current', true,
      'computed_at', now(), 'stored', false),
    jsonb_build_object('week_start', v_current - 7, 'week_end', v_current - 1, 'is_current', false,
      'computed_at', v_stored_at, 'stored', true),
    jsonb_build_object('week_start', v_current - 14, 'week_end', v_current - 8, 'is_current', false,
      'computed_at', now(), 'stored', false)
  ), 'admin_weekly_metrics: current live, stored week from the table, older week live, newest first';

  SELECT m.metrics INTO v_first FROM public.admin_weekly_metrics(1) m;
  ASSERT v_first ?& ARRAY[
    'active_baristas', 'active_businesses', 'active_approximate', 'new_baristas', 'new_businesses',
    'new_jobs', 'applications', 'offers', 'application_responses',
    'application_responses_within_72h_pct', 'application_response_median_hours',
    'offer_responses', 'shifts_closed', 'shifts_completed', 'pushes_sent'
  ], 'admin_weekly_metrics: live metrics carry every key';

  ASSERT (
    SELECT ARRAY[
      (SELECT count(*) FROM public.admin_weekly_metrics(0)),
      (SELECT count(*) FROM public.admin_weekly_metrics(100)),
      (SELECT count(*) FROM public.admin_weekly_metrics(NULL)),
      (SELECT count(*) FROM public.admin_weekly_metrics())
    ]
  ) = ARRAY[1, 52, 8, 8]::BIGINT[], 'admin_weekly_metrics: p_weeks clamped to 1..52, default 8';

  DELETE FROM public.weekly_metrics WHERE week_start = v_current - 7;
  PERFORM test.act_as(NULL);
  RAISE NOTICE 'ok: admin_weekly_metrics';
END $$;

-- ---------------------------------------------------------------------------
-- 6. store_weekly_metrics
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_previous DATE := date_trunc('week', now() AT TIME ZONE 'Europe/Moscow')::date - 7;
BEGIN
  ASSERT (SELECT count(*) FROM public.weekly_metrics) = 0, 'store_weekly_metrics: clean start';

  PERFORM app_internal.store_weekly_metrics();
  PERFORM app_internal.store_weekly_metrics();
  ASSERT (
    SELECT array_agg(ROW(w.week_start, w.computed_at, w.metrics = app_internal.compute_weekly_metrics(v_previous))::text)
    FROM public.weekly_metrics w
  ) = ARRAY[ROW(v_previous, now(), true)::text],
    'store_weekly_metrics: exactly one row for the previous week, upsert on repeat';

  RAISE NOTICE 'ok: store_weekly_metrics';
END $$;

-- ---------------------------------------------------------------------------
-- 7. grants and cron
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  ASSERT (
    SELECT ARRAY[
      has_function_privilege('anon', 'public.admin_weekly_metrics(int)', 'EXECUTE'),
      has_function_privilege('authenticated', 'public.admin_weekly_metrics(int)', 'EXECUTE'),
      has_function_privilege('anon', 'public.touch_last_seen()', 'EXECUTE'),
      has_function_privilege('authenticated', 'public.touch_last_seen()', 'EXECUTE'),
      has_function_privilege('authenticated', 'public.admin_last_seen(uuid[])', 'EXECUTE'),
      has_function_privilege('authenticated', 'app_internal.user_last_seen(uuid)', 'EXECUTE'),
      has_function_privilege('authenticated', 'app_internal.user_last_seen_bulk(uuid[])', 'EXECUTE'),
      has_function_privilege('authenticated', 'app_internal.compute_weekly_metrics(date)', 'EXECUTE'),
      has_function_privilege('authenticated', 'app_internal.store_weekly_metrics()', 'EXECUTE'),
      has_function_privilege('authenticated', 'public.set_responded_at_on_status_change()', 'EXECUTE')
    ]
  ) = ARRAY[false, true, false, true, false, false, false, false, false, false],
    'grants: admin RPC for authenticated only, internals for service_role only';

  ASSERT (SELECT ARRAY[j.schedule, j.command] FROM cron.job j WHERE j.jobname = 'store_weekly_metrics')
    = ARRAY['0 3 * * 1', 'SELECT app_internal.store_weekly_metrics();'],
    'cron: store_weekly_metrics scheduled Monday 03:00 UTC';

  ASSERT (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.user_activity_days'::regclass)
     AND (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.weekly_metrics'::regclass),
    'RLS enabled on user_activity_days and weekly_metrics';

  RAISE NOTICE 'ok: grants, cron, RLS';
END $$;

ROLLBACK;

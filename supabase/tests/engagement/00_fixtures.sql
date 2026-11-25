-- Minimal stand-in for the production schema, enough to apply migrations
-- 143+ (engagement loop) on a vanilla PostgreSQL 15 without PostGIS, pg_cron
-- or pg_net. Column lists mirror the real tables where the migrations touch
-- them; everything else is omitted. Run through run.sh, never against a real
-- database.

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS pgcrypto;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN CREATE ROLE anon NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN CREATE ROLE authenticated NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN CREATE ROLE service_role NOLOGIN BYPASSRLS; END IF;
END $$;

-- ---------------------------------------------------------------------------
-- auth (GoTrue) stubs
-- ---------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS auth;

CREATE TABLE auth.users (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  email TEXT,
  last_sign_in_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE auth.sessions (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id UUID NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now(),
  refreshed_at TIMESTAMP
);

-- Tests impersonate a user with: SELECT set_config('request.jwt.claim.sub', '<uuid>', true);
CREATE OR REPLACE FUNCTION auth.uid()
RETURNS UUID
LANGUAGE sql
STABLE
AS $$
  SELECT NULLIF(current_setting('request.jwt.claim.sub', true), '')::UUID;
$$;

-- ---------------------------------------------------------------------------
-- vault / cron / app_internal stubs
-- ---------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS vault;
CREATE TABLE vault.decrypted_secrets (name TEXT PRIMARY KEY, decrypted_secret TEXT);
INSERT INTO vault.decrypted_secrets VALUES
  ('app_supabase_url', 'http://stub.local'),
  ('app_service_role_key', 'stub-key');

CREATE SCHEMA IF NOT EXISTS cron;
CREATE TABLE cron.job (jobid BIGSERIAL PRIMARY KEY, jobname TEXT UNIQUE, schedule TEXT, command TEXT);
CREATE OR REPLACE FUNCTION cron.schedule(job_name TEXT, schedule TEXT, command TEXT)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE v_id BIGINT;
BEGIN
  INSERT INTO cron.job (jobname, schedule, command) VALUES (job_name, schedule, command)
  ON CONFLICT (jobname) DO UPDATE SET schedule = EXCLUDED.schedule, command = EXCLUDED.command
  RETURNING jobid INTO v_id;
  RETURN v_id;
END $$;
CREATE OR REPLACE FUNCTION cron.unschedule(job_name TEXT)
RETURNS BOOLEAN
LANGUAGE sql
AS $$ DELETE FROM cron.job WHERE jobname = job_name RETURNING true; $$;

CREATE SCHEMA IF NOT EXISTS app_internal;

-- Every push the DB would hand to the send-push edge function lands here so
-- tests can assert on dispatch instead of on HTTP.
CREATE TABLE app_internal.apns_dispatch_log (
  id BIGSERIAL PRIMARY KEY,
  recipient_id UUID,
  kind TEXT,
  payload JSONB,
  vault_ok BOOLEAN DEFAULT true,
  pg_net_request_id BIGINT,
  invoker TEXT,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE OR REPLACE FUNCTION app_internal.send_apns_invoke(payload JSONB)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  INSERT INTO app_internal.apns_dispatch_log (recipient_id, kind, payload, invoker)
  VALUES (NULLIF(payload->>'recipient_id', '')::UUID, payload->>'kind', payload, current_user);
END $$;

-- ---------------------------------------------------------------------------
-- public tables (subset)
-- ---------------------------------------------------------------------------
CREATE TABLE public.users (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  email TEXT UNIQUE NOT NULL,
  account_type TEXT NOT NULL CHECK (account_type IN ('barista', 'business')),
  is_active BOOLEAN DEFAULT true,
  is_admin BOOLEAN NOT NULL DEFAULT false,
  admin_role TEXT CHECK (admin_role IS NULL OR admin_role IN ('super_admin', 'moderator', 'support')),
  banned_at TIMESTAMPTZ,
  banned_by UUID,
  suspended_until TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE public.barista_profiles (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id UUID UNIQUE NOT NULL REFERENCES public.users (id) ON DELETE CASCADE,
  first_name TEXT,
  last_name TEXT,
  city TEXT NOT NULL DEFAULT 'spb',
  preferred_metro_stations TEXT[] DEFAULT '{}',
  is_actively_looking BOOLEAN DEFAULT true,
  profile_completeness INTEGER DEFAULT 0,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE public.businesses (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  owner_id UUID NOT NULL UNIQUE REFERENCES public.users (id) ON DELETE CASCADE,
  name TEXT,
  is_accepting_applications BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE public.branches (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  business_id UUID NOT NULL REFERENCES public.businesses (id) ON DELETE CASCADE,
  name TEXT,
  city TEXT NOT NULL DEFAULT 'spb',
  metro_station TEXT,
  is_active BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE public.jobs (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  business_id UUID NOT NULL REFERENCES public.businesses (id) ON DELETE CASCADE,
  business_owner_id UUID NOT NULL REFERENCES public.users (id) ON DELETE CASCADE,
  branch_id UUID NOT NULL REFERENCES public.branches (id) ON DELETE CASCADE,
  job_type TEXT NOT NULL DEFAULT 'temporary' CHECK (job_type IN ('temporary', 'permanent')),
  title TEXT NOT NULL DEFAULT 'Shift',
  description TEXT,
  location JSONB,
  shift_details JSONB,
  compensation JSONB,
  status TEXT DEFAULT 'open' CHECK (status IN ('open', 'in_review', 'filled', 'expired', 'cancelled')),
  application_count INTEGER DEFAULT 0,
  posted_at TIMESTAMPTZ DEFAULT now(),
  expires_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE public.applications (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  job_id UUID NOT NULL REFERENCES public.jobs (id) ON DELETE CASCADE,
  barista_id UUID NOT NULL REFERENCES public.users (id) ON DELETE CASCADE,
  status TEXT DEFAULT 'pending' CHECK (status IN ('pending', 'under_review', 'accepted', 'rejected', 'withdrawn')),
  cover_letter TEXT,
  created_via_offer BOOLEAN NOT NULL DEFAULT FALSE,
  completed_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now(),
  CONSTRAINT unique_application UNIQUE (job_id, barista_id)
);

CREATE TABLE public.job_offers (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  business_owner_id UUID NOT NULL REFERENCES public.users (id) ON DELETE CASCADE,
  barista_id UUID NOT NULL REFERENCES public.users (id) ON DELETE CASCADE,
  job_id UUID NOT NULL REFERENCES public.jobs (id) ON DELETE CASCADE,
  message TEXT,
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'accepted', 'declined', 'expired', 'cancelled')),
  application_id UUID REFERENCES public.applications (id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  responded_at TIMESTAMPTZ
);

CREATE OR REPLACE FUNCTION public.update_updated_at_column()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END $$;

CREATE TRIGGER update_applications_updated_at
  BEFORE UPDATE ON public.applications
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

CREATE TRIGGER update_users_updated_at
  BEFORE UPDATE ON public.users
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

-- notifications: kind check as of migration 136.
CREATE TABLE public.notifications (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id UUID NOT NULL REFERENCES public.users (id) ON DELETE CASCADE,
  kind TEXT NOT NULL,
  title TEXT,
  body TEXT,
  data JSONB NOT NULL DEFAULT '{}'::jsonb,
  read_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.notifications ADD CONSTRAINT notifications_kind_check CHECK (kind IN (
  'new_message', 'application_accepted', 'application_rejected',
  'work_completion_requested', 'work_completion_confirmed', 'new_application',
  'application_withdrawn', 'shift_cancelled', 'new_review', 'conversation_started',
  'job_offer_received', 'job_offer_accepted', 'job_offer_declined',
  'shift_reminder_24h', 'shift_reminder_3h', 'shift_confirmation_required',
  'shift_confirmed', 'shift_declined', 'shift_no_response_alert', 'dispute_filed',
  'broadcast', 'admin_dm', 'employment_started', 'employment_start_due',
  'employment_end_requested', 'employment_ended', 'job_start_reminder',
  'report_resolved', 'complaint_info_requested', 'complaint_resolved'
));
ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;

-- notification_preferences: columns as of migration 124.
CREATE TABLE public.notification_preferences (
  user_id UUID PRIMARY KEY REFERENCES public.users (id) ON DELETE CASCADE,
  new_message BOOLEAN DEFAULT true,
  application_accepted BOOLEAN DEFAULT true,
  application_rejected BOOLEAN DEFAULT true,
  new_application BOOLEAN DEFAULT true,
  application_withdrawn BOOLEAN DEFAULT true,
  shift_cancelled BOOLEAN DEFAULT true,
  new_review BOOLEAN DEFAULT true,
  conversation_started BOOLEAN DEFAULT true,
  job_offer_received BOOLEAN DEFAULT true,
  job_offer_accepted BOOLEAN DEFAULT true,
  job_offer_declined BOOLEAN DEFAULT true,
  work_completion_requested BOOLEAN DEFAULT true,
  work_completion_confirmed BOOLEAN DEFAULT true,
  shift_reminder_24h BOOLEAN NOT NULL DEFAULT true,
  shift_reminder_3h BOOLEAN NOT NULL DEFAULT true,
  shift_confirmed BOOLEAN NOT NULL DEFAULT true,
  shift_declined BOOLEAN NOT NULL DEFAULT true,
  employment_started BOOLEAN NOT NULL DEFAULT true,
  employment_ended BOOLEAN NOT NULL DEFAULT true,
  updated_at TIMESTAMPTZ DEFAULT now()
);
ALTER TABLE public.notification_preferences ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.device_tokens (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id UUID NOT NULL REFERENCES public.users (id) ON DELETE CASCADE,
  device_token TEXT NOT NULL,
  environment TEXT NOT NULL CHECK (environment IN ('sandbox', 'production', 'web')),
  platform TEXT NOT NULL DEFAULT 'ios' CHECK (platform IN ('ios', 'android', 'web')),
  p256dh TEXT,
  auth TEXT,
  last_seen_at TIMESTAMPTZ DEFAULT now(),
  created_at TIMESTAMPTZ DEFAULT now(),
  CONSTRAINT unique_user_device UNIQUE (user_id, device_token)
);

CREATE TABLE public.feature_flags (
  key TEXT PRIMARY KEY,
  value JSONB NOT NULL,
  updated_by UUID REFERENCES public.users (id),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.feature_flags ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.audit_log (
  id BIGSERIAL PRIMARY KEY,
  admin_id UUID NOT NULL REFERENCES public.users (id),
  action TEXT NOT NULL,
  target_table TEXT NOT NULL,
  target_id UUID,
  before JSONB,
  after JSONB,
  reason TEXT NOT NULL CHECK (length(reason) >= 10),
  ip INET,
  user_agent TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE public.broadcasts (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  segment JSONB NOT NULL,
  title TEXT NOT NULL,
  body TEXT NOT NULL,
  channel TEXT[] NOT NULL DEFAULT ARRAY['push']::TEXT[],
  scheduled_for TIMESTAMPTZ,
  sent_at TIMESTAMPTZ,
  delivered_count INT NOT NULL DEFAULT 0,
  opened_count INT NOT NULL DEFAULT 0,
  created_by UUID NOT NULL REFERENCES public.users (id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- user_activity + touch_last_seen + admin_last_seen as of migration 134.
CREATE TABLE public.user_activity (
  user_id UUID PRIMARY KEY REFERENCES auth.users (id) ON DELETE CASCADE,
  last_seen_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.user_activity ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.touch_last_seen()
RETURNS void
LANGUAGE sql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $fn$
  INSERT INTO public.user_activity (user_id, last_seen_at)
  SELECT auth.uid(), now()
  WHERE auth.uid() IS NOT NULL
  ON CONFLICT (user_id) DO UPDATE
    SET last_seen_at = EXCLUDED.last_seen_at
    WHERE public.user_activity.last_seen_at < EXCLUDED.last_seen_at - INTERVAL '5 minutes';
$fn$;
REVOKE EXECUTE ON FUNCTION public.touch_last_seen() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.touch_last_seen() TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_last_seen(p_user_ids UUID[])
RETURNS TABLE (id UUID, last_seen_at TIMESTAMPTZ)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $fn$
  SELECT u.id, GREATEST(a.last_seen_at, d.last_seen_at)
  FROM unnest(p_user_ids) AS u (id)
  LEFT JOIN public.user_activity a ON a.user_id = u.id
  LEFT JOIN LATERAL (
    SELECT max(t.last_seen_at) AS last_seen_at
    FROM public.device_tokens t
    WHERE t.user_id = u.id
  ) d ON true;
$fn$;
REVOKE EXECUTE ON FUNCTION public.admin_last_seen(UUID[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_last_seen(UUID[]) TO service_role;

-- ---------------------------------------------------------------------------
-- admin helpers (101 / 103)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.is_admin()
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.users
    WHERE id = (SELECT auth.uid()) AND is_admin = true AND banned_at IS NULL
  );
$$;

CREATE OR REPLACE FUNCTION public.raise_admin_only()
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $fn$
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'admin only' USING ERRCODE = '42501';
  END IF;
END;
$fn$;

CREATE OR REPLACE FUNCTION public.super_admin_only()
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $fn$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.users
    WHERE id = (SELECT auth.uid()) AND is_admin = true AND admin_role = 'super_admin' AND banned_at IS NULL
  ) THEN
    RAISE EXCEPTION 'super_admin only' USING ERRCODE = '42501';
  END IF;
END;
$fn$;

-- admin_feature_flag_set as of migration 110.
CREATE OR REPLACE FUNCTION public.admin_feature_flag_set(
  p_key TEXT,
  p_value JSONB,
  p_reason TEXT
)
RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $fn$
DECLARE
  v_admin_id UUID := (SELECT auth.uid());
  v_before JSONB;
  v_audit_id BIGINT;
BEGIN
  PERFORM public.raise_admin_only();
  IF p_reason IS NULL OR length(p_reason) < 10 THEN
    RAISE EXCEPTION 'admin_feature_flag_set: reason must be at least 10 characters' USING ERRCODE = '22023';
  END IF;
  SELECT to_jsonb(f.*) INTO v_before FROM public.feature_flags f WHERE key = p_key;
  INSERT INTO public.feature_flags (key, value, updated_by, updated_at)
  VALUES (p_key, p_value, v_admin_id, now())
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_by = EXCLUDED.updated_by, updated_at = now();
  INSERT INTO public.audit_log (admin_id, action, target_table, target_id, before, after, reason)
  VALUES (v_admin_id, 'feature_flag.set', 'feature_flags', NULL, v_before, jsonb_build_object('key', p_key, 'value', p_value), p_reason)
  RETURNING id INTO v_audit_id;
  RETURN v_audit_id;
END;
$fn$;

-- notify_admin_initiated_notification as of migration 110.
CREATE OR REPLACE FUNCTION public.notify_admin_initiated_notification()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, app_internal
AS $fn$
BEGIN
  IF NEW.kind NOT IN ('broadcast', 'admin_dm') THEN
    RETURN NEW;
  END IF;

  BEGIN
    PERFORM app_internal.send_apns_invoke(
      jsonb_build_object(
        'recipient_id', NEW.user_id,
        'kind', NEW.kind,
        'title', NEW.title,
        'body', NEW.body,
        'data', COALESCE(NEW.data, '{}'::jsonb) || jsonb_build_object('kind', NEW.kind)
      )
    );
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'send-apns call failed (%): %', NEW.kind, SQLERRM;
  END;

  RETURN NEW;
END;
$fn$;


CREATE TRIGGER trigger_notify_admin_initiated
  AFTER INSERT ON public.notifications
  FOR EACH ROW
  EXECUTE FUNCTION public.notify_admin_initiated_notification();

REVOKE EXECUTE ON FUNCTION public.notify_admin_initiated_notification() FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Test helpers
-- ---------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS test;

-- Creates an auth.users + public.users pair (plus barista_profiles / businesses
-- row by account type) and returns the id.
CREATE OR REPLACE FUNCTION test.make_user(
  p_email TEXT,
  p_account_type TEXT DEFAULT 'barista',
  p_is_admin BOOLEAN DEFAULT false,
  p_created_at TIMESTAMPTZ DEFAULT now()
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE v_id UUID := uuid_generate_v4();
BEGIN
  INSERT INTO auth.users (id, email, created_at) VALUES (v_id, p_email, p_created_at);
  INSERT INTO public.users (id, email, account_type, is_admin, admin_role, created_at, updated_at)
  VALUES (v_id, p_email, p_account_type, p_is_admin,
          CASE WHEN p_is_admin THEN 'super_admin' END, p_created_at, p_created_at);
  IF p_account_type = 'barista' THEN
    INSERT INTO public.barista_profiles (user_id, city, profile_completeness, created_at, updated_at)
    VALUES (v_id, 'spb', 50, p_created_at, p_created_at);
  ELSE
    INSERT INTO public.businesses (owner_id, name, created_at, updated_at)
    VALUES (v_id, p_email, p_created_at, p_created_at);
  END IF;
  RETURN v_id;
END $$;

-- Impersonate a user for auth.uid() within the current transaction.
CREATE OR REPLACE FUNCTION test.act_as(p_user_id UUID)
RETURNS VOID
LANGUAGE sql
AS $$ SELECT set_config('request.jwt.claim.sub', COALESCE(p_user_id::TEXT, ''), true); $$;

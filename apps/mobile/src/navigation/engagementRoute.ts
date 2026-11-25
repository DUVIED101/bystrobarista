import type { AccountType } from '@bystrobarista/core/types/user';
import {
  ENGAGEMENT_NOTIFICATION_KINDS,
  type NotificationData,
  type NotificationKind,
} from '@bystrobarista/core/types/notification';

type TabRoute = { tab: string; child?: { screen: string; params?: object } };
type UrlRoute = { openUrl: string };
export type EngagementRoute = TabRoute | UrlRoute;

const ENGAGEMENT_KINDS = new Set<NotificationKind>(ENGAGEMENT_NOTIFICATION_KINDS);

const httpsUrl = (raw: string | undefined): string | null => {
  if (!raw) return null;
  try {
    const url = new URL(raw);
    return url.protocol === 'https:' ? url.toString() : null;
  } catch {
    return null;
  }
};

export const resolveEngagementRoute = (
  kind: NotificationKind,
  accountType: AccountType | undefined,
  data: NotificationData | undefined
): EngagementRoute | null => {
  if (!ENGAGEMENT_KINDS.has(kind)) return null;

  const jobId = data?.jobId;
  const offerId = data?.offerId;

  if (kind === 'new_job_nearby') {
    return jobId
      ? { tab: 'Jobs', child: { screen: 'JobDetails', params: { jobId } } }
      : { tab: 'Jobs', child: { screen: 'JobFeed' } };
  }

  if (kind === 'weekly_digest' || kind === 'recurring_broadcast') {
    if (accountType === 'barista') return { tab: 'Jobs', child: { screen: 'JobFeed' } };
    if (accountType === 'business') return { tab: 'Baristas', child: { screen: 'BaristaFeed' } };
    return null;
  }

  if (kind === 'application_reminder') {
    return jobId
      ? { tab: 'Business', child: { screen: 'Applicants', params: { jobId } } }
      : { tab: 'Business' };
  }

  if (kind === 'application_expired') {
    return { tab: 'Jobs', child: { screen: 'JobFeed' } };
  }

  if (kind === 'job_offer_reminder') {
    return offerId
      ? { tab: 'Jobs', child: { screen: 'JobOffer', params: { offerId } } }
      : { tab: 'Jobs' };
  }

  if (kind === 'job_offer_expired') {
    return { tab: 'Baristas' };
  }

  if (kind === 'profile_hidden') {
    return { tab: 'Profile', child: { screen: 'BaristaProfileSetup' } };
  }

  const storeUrl = httpsUrl(data?.storeUrl);
  return storeUrl
    ? { openUrl: storeUrl }
    : { tab: 'Profile', child: { screen: 'NotificationFeed' } };
};

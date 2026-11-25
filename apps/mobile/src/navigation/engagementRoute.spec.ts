import { resolveEngagementRoute } from './engagementRoute';
import type { NotificationData } from '@bystrobarista/core/types/notification';
import type { JobId, JobOfferId } from '@bystrobarista/core/types/ids';

const jobId = 'job-1' as JobId;
const offerId = 'offer-1' as JobOfferId;
const storeUrl = 'https://apps.apple.com/ru/app/id123';

const data = (overrides: Partial<NotificationData> = {}): NotificationData => ({
  kind: 'new_job_nearby',
  ...overrides,
});

describe('resolveEngagementRoute', () => {
  it.each([
    [
      'new_job_nearby with jobId opens the job card',
      'new_job_nearby',
      'barista',
      data({ jobId }),
      { tab: 'Jobs', child: { screen: 'JobDetails', params: { jobId } } },
    ],
    [
      'new_job_nearby without jobId opens the job feed',
      'new_job_nearby',
      'barista',
      data(),
      { tab: 'Jobs', child: { screen: 'JobFeed' } },
    ],
    [
      'weekly_digest for a barista opens the job feed',
      'weekly_digest',
      'barista',
      data(),
      { tab: 'Jobs', child: { screen: 'JobFeed' } },
    ],
    [
      'weekly_digest for a business opens the barista feed',
      'weekly_digest',
      'business',
      data(),
      { tab: 'Baristas', child: { screen: 'BaristaFeed' } },
    ],
    [
      'recurring_broadcast for a barista opens the job feed',
      'recurring_broadcast',
      'barista',
      data(),
      { tab: 'Jobs', child: { screen: 'JobFeed' } },
    ],
    [
      'recurring_broadcast for a business opens the barista feed',
      'recurring_broadcast',
      'business',
      data(),
      { tab: 'Baristas', child: { screen: 'BaristaFeed' } },
    ],
    [
      'application_reminder with jobId opens the applicants list',
      'application_reminder',
      'business',
      data({ jobId }),
      { tab: 'Business', child: { screen: 'Applicants', params: { jobId } } },
    ],
    [
      'application_reminder without jobId opens the business home',
      'application_reminder',
      'business',
      data(),
      { tab: 'Business' },
    ],
    [
      'application_expired opens the job feed',
      'application_expired',
      'barista',
      data(),
      { tab: 'Jobs', child: { screen: 'JobFeed' } },
    ],
    [
      'job_offer_reminder with offerId opens the offer',
      'job_offer_reminder',
      'barista',
      data({ offerId }),
      { tab: 'Jobs', child: { screen: 'JobOffer', params: { offerId } } },
    ],
    [
      'job_offer_reminder without offerId opens the jobs tab',
      'job_offer_reminder',
      'barista',
      data(),
      { tab: 'Jobs' },
    ],
    [
      'job_offer_expired opens the baristas tab',
      'job_offer_expired',
      'business',
      data(),
      { tab: 'Baristas' },
    ],
    [
      'profile_hidden opens the profile editor',
      'profile_hidden',
      'barista',
      data(),
      { tab: 'Profile', child: { screen: 'BaristaProfileSetup' } },
    ],
    [
      'app_update with an https storeUrl opens the store',
      'app_update',
      'barista',
      data({ storeUrl }),
      { openUrl: storeUrl },
    ],
    [
      'app_update with an http storeUrl falls back to the notification feed',
      'app_update',
      'barista',
      data({ storeUrl: 'http://apps.apple.com/ru/app/id123' }),
      { tab: 'Profile', child: { screen: 'NotificationFeed' } },
    ],
    [
      'app_update with a javascript storeUrl falls back to the notification feed',
      'app_update',
      'barista',
      data({ storeUrl: 'javascript:alert(1)' }),
      { tab: 'Profile', child: { screen: 'NotificationFeed' } },
    ],
    [
      'app_update without storeUrl opens the notification feed',
      'app_update',
      'business',
      data(),
      { tab: 'Profile', child: { screen: 'NotificationFeed' } },
    ],
  ] as const)('%s', (_label, kind, accountType, payloadData, expected) => {
    expect(resolveEngagementRoute(kind, accountType, payloadData)).toEqual(expected);
  });

  it('returns null for kinds outside the engagement loop', () => {
    expect(resolveEngagementRoute('new_message', 'barista', data({ kind: 'new_message' }))).toBe(
      null
    );
  });

  it.each(['weekly_digest', 'recurring_broadcast'] as const)(
    'returns null for %s when the account type is unknown',
    kind => {
      expect(resolveEngagementRoute(kind, undefined, data())).toBe(null);
    }
  );
});

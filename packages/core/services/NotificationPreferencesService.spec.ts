import type { UserId } from '@bystrobarista/core/types/ids';
import type { NotificationPreferences } from '@bystrobarista/core/types/notificationPreferences';

const mockFrom = jest.fn();

jest.mock('../config/supabase', () => ({
  supabase: { from: (...args: unknown[]) => mockFrom(...args) },
}));

// Import after jest.mock so the service receives the mocked client.
import { NotificationPreferencesService } from './NotificationPreferencesService';

const USER_ID = 'user-uuid-1' as UserId;
const UPDATED_AT_ISO = '2026-11-25T09:00:00.000Z';
const NOT_FOUND_CODE = 'PGRST116';

const LEGACY_ROW = {
  user_id: USER_ID,
  new_message: true,
  application_accepted: false,
  application_rejected: true,
  new_application: false,
  application_withdrawn: true,
  shift_cancelled: false,
  new_review: true,
  conversation_started: false,
  job_offer_received: true,
  job_offer_accepted: false,
  job_offer_declined: true,
  work_completion_requested: false,
  work_completion_confirmed: true,
  employment_started: false,
  employment_ended: true,
  updated_at: UPDATED_AT_ISO,
};

const FULL_ROW = {
  ...LEGACY_ROW,
  new_job_nearby: false,
  response_reminders: true,
  weekly_digest: false,
  product_news: true,
};

const LEGACY_PREFS: Omit<
  NotificationPreferences,
  'newJobNearby' | 'responseReminders' | 'weeklyDigest' | 'productNews'
> = {
  userId: USER_ID,
  newMessage: true,
  applicationAccepted: false,
  applicationRejected: true,
  newApplication: false,
  applicationWithdrawn: true,
  shiftCancelled: false,
  newReview: true,
  conversationStarted: false,
  jobOfferReceived: true,
  jobOfferAccepted: false,
  jobOfferDeclined: true,
  workCompletionRequested: false,
  workCompletionConfirmed: true,
  employmentStarted: false,
  employmentEnded: true,
  updatedAt: UPDATED_AT_ISO,
};

type QueryCapture = {
  tables: string[];
  selectArgs: unknown[];
  eqCalls: Array<[string, unknown]>;
  upsertRow: Record<string, unknown> | null;
  upsertOptions: unknown;
};

const newCapture = (): QueryCapture => ({
  tables: [],
  selectArgs: [],
  eqCalls: [],
  upsertRow: null,
  upsertOptions: null,
});

type SingleResult = { data: unknown; error: { code: string } | null };

// One chainable fake serving both reads (select().eq().single()) and writes
// (upsert().select().single()).
const useTableMock = (capture: QueryCapture, result: SingleResult): void => {
  mockFrom.mockImplementation((table: string) => {
    capture.tables.push(table);
    const builder = {
      select: jest.fn((...args: unknown[]) => {
        capture.selectArgs.push(args);
        return builder;
      }),
      eq: jest.fn((column: string, value: unknown) => {
        capture.eqCalls.push([column, value]);
        return builder;
      }),
      upsert: jest.fn((row: Record<string, unknown>, options: unknown) => {
        capture.upsertRow = row;
        capture.upsertOptions = options;
        return builder;
      }),
      single: jest.fn(() => Promise.resolve(result)),
    };
    return builder;
  });
};

beforeEach(() => {
  mockFrom.mockReset();
  jest.spyOn(console, 'error').mockImplementation(() => undefined);
});

afterEach(() => {
  jest.restoreAllMocks();
});

describe('getPreferences', () => {
  it('maps a full snake_case row to camelCase including the engagement fields', async () => {
    const capture = newCapture();
    useTableMock(capture, { data: FULL_ROW, error: null });

    const result = await NotificationPreferencesService.getPreferences(USER_ID);

    expect(capture.tables).toEqual(['notification_preferences']);
    expect(capture.eqCalls).toEqual([['user_id', USER_ID]]);
    expect(result).toEqual({
      ...LEGACY_PREFS,
      newJobNearby: false,
      responseReminders: true,
      weeklyDigest: false,
      productNews: true,
    });
  });

  it('defaults the engagement fields to true when a pre-migration row lacks them', async () => {
    const capture = newCapture();
    useTableMock(capture, { data: LEGACY_ROW, error: null });

    const result = await NotificationPreferencesService.getPreferences(USER_ID);

    expect(result).toEqual({
      ...LEGACY_PREFS,
      newJobNearby: true,
      responseReminders: true,
      weeklyDigest: true,
      productNews: true,
    });
  });

  it('returns null when the row does not exist', async () => {
    const capture = newCapture();
    useTableMock(capture, { data: null, error: { code: NOT_FOUND_CODE } });

    const result = await NotificationPreferencesService.getPreferences(USER_ID);

    expect(result).toBeNull();
  });
});

describe('upsertPreferences', () => {
  it('upserts only the provided keys as snake_case columns keyed on user_id', async () => {
    const capture = newCapture();
    useTableMock(capture, {
      data: { ...FULL_ROW, product_news: false, new_message: false },
      error: null,
    });

    await NotificationPreferencesService.upsertPreferences(USER_ID, {
      productNews: false,
      newMessage: false,
      weeklyDigest: undefined,
    });

    expect(capture.tables).toEqual(['notification_preferences']);
    expect(capture.upsertRow).toEqual({
      user_id: USER_ID,
      product_news: false,
      new_message: false,
    });
    expect(capture.upsertOptions).toEqual({ onConflict: 'user_id' });
  });
});

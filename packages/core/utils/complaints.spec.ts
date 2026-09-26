import type { ComplaintListItem } from '../types/complaint';
import type { DisputeId, UserReportId } from '../types/ids';
import {
  complaintReasonKeys,
  complaintRefFromNotification,
  complaintStatusGroup,
  complaintTitle,
  mapComplaintDetails,
  mapComplaintRow,
  reportSubmitErrorKey,
  splitComplaintsByRole,
  type ComplaintDetailsRow,
  type ComplaintRow,
} from './complaints';

const REPORT_ID = 'report-1';
const DISPUTE_ID = 'dispute-1';
const APPLICATION_ID = 'app-1';
const FILED_AT = '2026-09-20T10:15:00Z';
const RESOLVED_AT = '2026-09-22T08:00:00Z';

const reportRow = (overrides: Partial<ComplaintRow> = {}): ComplaintRow => ({
  kind: 'report',
  id: REPORT_ID,
  my_role: 'reporter',
  status: 'open',
  outcome: null,
  reason_codes: ['harassment'],
  severity: null,
  target_type: 'message',
  application_id: null,
  job_title: null,
  business_name: null,
  subject_label: 'Анна Петрова',
  created_at: FILED_AT,
  resolved_at: null,
  needs_my_reply: false,
  last_activity_at: FILED_AT,
  ...overrides,
});

const disputeRow = (overrides: Partial<ComplaintRow> = {}): ComplaintRow => ({
  kind: 'dispute',
  id: DISPUTE_ID,
  my_role: 'target',
  status: 'under_review',
  outcome: null,
  reason_codes: ['no_show', 'intoxication'],
  severity: 'serious',
  target_type: null,
  application_id: APPLICATION_ID,
  job_title: 'Бариста на выходные',
  business_name: 'Кофейня на Мясницкой',
  subject_label: null,
  created_at: '2026-09-20T00:00:00Z',
  resolved_at: null,
  needs_my_reply: true,
  last_activity_at: '2026-09-21T12:00:00Z',
  ...overrides,
});

const item = (overrides: Partial<ComplaintListItem>): ComplaintListItem => ({
  ref: { kind: 'report', id: REPORT_ID as UserReportId },
  myRole: 'reporter',
  status: 'open',
  outcome: null,
  reasonCodes: [],
  severity: null,
  targetType: null,
  applicationId: null,
  jobTitle: null,
  businessName: null,
  subjectLabel: null,
  createdAt: FILED_AT,
  resolvedAt: null,
  needsMyReply: false,
  lastActivityAt: FILED_AT,
  ...overrides,
});

describe('complaintStatusGroup', () => {
  it.each([
    ['open', 'open'],
    ['submitted', 'open'],
    ['triaged', 'in_review'],
    ['under_review', 'in_review'],
    ['resolved', 'resolved'],
    ['dismissed', 'dismissed'],
    ['something_new', 'open'],
  ] as const)('maps %s to %s', (status, expected) => {
    expect(complaintStatusGroup(status)).toEqual(expected);
  });
});

describe('mapComplaintRow', () => {
  it('maps a report the caller filed', () => {
    expect(mapComplaintRow(reportRow())).toEqual({
      ref: { kind: 'report', id: REPORT_ID },
      myRole: 'reporter',
      status: 'open',
      outcome: null,
      reasonCodes: ['harassment'],
      severity: null,
      targetType: 'message',
      applicationId: null,
      jobTitle: null,
      businessName: null,
      subjectLabel: 'Анна Петрова',
      createdAt: FILED_AT,
      resolvedAt: null,
      needsMyReply: false,
      lastActivityAt: FILED_AT,
    });
  });

  it('maps a resolved dispute against the caller with its shift context', () => {
    const row = disputeRow({ status: 'resolved', outcome: 'warning', resolved_at: RESOLVED_AT });
    expect(mapComplaintRow(row)).toEqual({
      ref: { kind: 'dispute', id: DISPUTE_ID },
      myRole: 'target',
      status: 'resolved',
      outcome: 'warning',
      reasonCodes: ['no_show', 'intoxication'],
      severity: 'serious',
      targetType: null,
      applicationId: APPLICATION_ID,
      jobTitle: 'Бариста на выходные',
      businessName: 'Кофейня на Мясницкой',
      subjectLabel: null,
      createdAt: '2026-09-20T00:00:00Z',
      resolvedAt: RESOLVED_AT,
      needsMyReply: true,
      lastActivityAt: '2026-09-21T12:00:00Z',
    });
  });

  it('treats missing reason codes and reply flag as empty and false', () => {
    const mapped = mapComplaintRow(reportRow({ reason_codes: null, needs_my_reply: null }));
    expect([mapped.reasonCodes, mapped.needsMyReply]).toEqual([[], false]);
  });
});

describe('mapComplaintDetails', () => {
  const detailsRow = (overrides: Partial<ComplaintDetailsRow> = {}): ComplaintDetailsRow => ({
    ...disputeRow(),
    own_text: null,
    moderator_note: null,
    thread: [
      { author_role: 'admin', body: 'Расскажите вашу версию', created_at: '2026-09-21T11:00:00Z' },
      { author_role: 'participant', body: 'Я был на смене', created_at: '2026-09-21T12:00:00Z' },
    ],
    can_reply: true,
    ...overrides,
  });

  it('maps the thread, the moderator note and the reply permission', () => {
    const mapped = mapComplaintDetails(
      detailsRow({ moderator_note: 'Нарушение не подтвердилось' })
    );
    expect({
      ownText: mapped.ownText,
      moderatorNote: mapped.moderatorNote,
      thread: mapped.thread,
      canReply: mapped.canReply,
      ref: mapped.ref,
    }).toEqual({
      ownText: null,
      moderatorNote: 'Нарушение не подтвердилось',
      thread: [
        { authorRole: 'admin', body: 'Расскажите вашу версию', createdAt: '2026-09-21T11:00:00Z' },
        { authorRole: 'participant', body: 'Я был на смене', createdAt: '2026-09-21T12:00:00Z' },
      ],
      canReply: true,
      ref: { kind: 'dispute', id: DISPUTE_ID },
    });
  });

  it('keeps the reporter own text and treats a missing thread as empty', () => {
    const mapped = mapComplaintDetails(
      detailsRow({
        my_role: 'reporter',
        own_text: 'Опоздал на два часа',
        thread: null,
        can_reply: null,
      })
    );
    expect([mapped.ownText, mapped.thread, mapped.canReply]).toEqual([
      'Опоздал на два часа',
      [],
      false,
    ]);
  });
});

describe('splitComplaintsByRole', () => {
  it('splits by role and sorts each tab by latest activity first', () => {
    const oldMine = item({ lastActivityAt: '2026-09-01T00:00:00Z' });
    const newMine = item({ lastActivityAt: '2026-09-10T00:00:00Z' });
    const against = item({ myRole: 'target', lastActivityAt: '2026-09-05T00:00:00Z' });
    expect(splitComplaintsByRole([oldMine, against, newMine])).toEqual({
      mine: [newMine, oldMine],
      against: [against],
    });
  });

  it('returns two empty tabs for no complaints', () => {
    expect(splitComplaintsByRole([])).toEqual({ mine: [], against: [] });
  });
});

describe('complaintRefFromNotification', () => {
  it.each([
    [
      'complaint fields',
      { complaintKind: 'dispute', complaintId: DISPUTE_ID },
      { kind: 'dispute', id: DISPUTE_ID as DisputeId },
    ],
    [
      'a legacy report_resolved payload',
      { reportId: REPORT_ID },
      { kind: 'report', id: REPORT_ID as UserReportId },
    ],
    [
      'a legacy dispute_filed payload',
      { disputeId: DISPUTE_ID },
      { kind: 'dispute', id: DISPUTE_ID as DisputeId },
    ],
    ['an unknown complaint kind', { complaintKind: 'appeal', complaintId: REPORT_ID }, null],
    ['no complaint fields', {}, null],
  ])('reads %s', (_label, data, expected) => {
    expect(complaintRefFromNotification(data)).toEqual(expected);
  });

  it('prefers the complaint fields over the legacy ids', () => {
    expect(
      complaintRefFromNotification({
        complaintKind: 'report',
        complaintId: REPORT_ID,
        disputeId: DISPUTE_ID,
      })
    ).toEqual({ kind: 'report', id: REPORT_ID });
  });
});

describe('reportSubmitErrorKey', () => {
  it.each([
    [
      'a duplicate open report',
      { code: '23505', message: 'duplicate key value' },
      'report.alreadyReported',
    ],
    ['the daily limit', { code: 'P0001', message: 'REPORT_RATE_LIMIT' }, 'report.rateLimited'],
    [
      'a deleted object',
      { code: 'P0001', message: 'REPORT_TARGET_NOT_FOUND' },
      'report.targetGone',
    ],
    ['a report about yourself', { code: 'P0001', message: 'REPORT_SELF' }, 'report.error'],
    ['a network failure', new Error('Network request failed'), 'report.error'],
    ['a non-error value', 'boom', 'report.error'],
  ])('maps %s to its message key', (_label, error, expected) => {
    expect(reportSubmitErrorKey(error)).toEqual(expected);
  });
});

describe('complaintReasonKeys', () => {
  it('uses report reasons for a report', () => {
    expect(complaintReasonKeys(item({ reasonCodes: ['spam'] }))).toEqual(['report.reason.spam']);
  });

  it('uses dispute categories for a dispute', () => {
    const dispute = item({
      ref: { kind: 'dispute', id: DISPUTE_ID as DisputeId },
      reasonCodes: ['no_show', 'unpaid'],
    });
    expect(complaintReasonKeys(dispute)).toEqual([
      'disputes.category.no_show',
      'disputes.category.unpaid',
    ]);
  });
});

describe('complaintTitle', () => {
  const t = (key: string): string => `[${key}]`;

  it.each([
    [
      'a report I filed names the subject',
      item({ targetType: 'user', subjectLabel: 'Анна Петрова' }),
      '[complaints.about.user]: Анна Петрова',
    ],
    [
      'a report I filed without a subject label',
      item({ targetType: 'review' }),
      '[complaints.about.review]',
    ],
    [
      'a report about my message stays anonymous',
      item({ myRole: 'target', targetType: 'message' }),
      '[complaints.aboutMe.message]',
    ],
    [
      'a report about my job names my own job',
      item({ myRole: 'target', targetType: 'job', subjectLabel: 'Бариста в утро' }),
      '[complaints.aboutMe.job]: Бариста в утро',
    ],
    [
      'a dispute uses the job title',
      item({ ref: { kind: 'dispute', id: DISPUTE_ID as DisputeId }, jobTitle: 'Смена в субботу' }),
      'Смена в субботу',
    ],
    [
      'a dispute without a job title',
      item({ ref: { kind: 'dispute', id: DISPUTE_ID as DisputeId } }),
      '[complaints.about.shift]',
    ],
  ])('%s', (_label, complaint, expected) => {
    expect(complaintTitle(complaint, t)).toEqual(expected);
  });
});

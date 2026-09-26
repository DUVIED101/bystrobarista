import type {
  ComplaintDetails,
  ComplaintListItem,
  ComplaintRef,
  ComplaintStatusGroup,
} from '../types/complaint';
import type { ApplicationId, DisputeId, UserReportId } from '../types/ids';
import type { ReportOutcome, ReportTargetType } from '../types/userReport';

export type ComplaintRow = {
  kind: 'report' | 'dispute';
  id: string;
  my_role: 'reporter' | 'target';
  status: string;
  outcome: string | null;
  reason_codes: string[] | null;
  severity: string | null;
  target_type: string | null;
  application_id: string | null;
  job_title: string | null;
  business_name: string | null;
  subject_label: string | null;
  created_at: string;
  resolved_at: string | null;
  needs_my_reply: boolean | null;
  last_activity_at: string;
};

export type ComplaintDetailsRow = ComplaintRow & {
  own_text: string | null;
  moderator_note: string | null;
  thread: { author_role: 'admin' | 'participant'; body: string; created_at: string }[] | null;
  can_reply: boolean | null;
};

export type ComplaintNotificationData = {
  complaintKind?: string;
  complaintId?: string;
  reportId?: string;
  disputeId?: string;
};

const STATUS_GROUPS: Record<string, ComplaintStatusGroup> = {
  open: 'open',
  submitted: 'open',
  triaged: 'in_review',
  under_review: 'in_review',
  resolved: 'resolved',
  dismissed: 'dismissed',
};

export function complaintStatusGroup(status: string): ComplaintStatusGroup {
  return STATUS_GROUPS[status] ?? 'open';
}

function complaintRef(kind: string, id: string): ComplaintRef | null {
  if (kind === 'report') return { kind, id: id as UserReportId };
  if (kind === 'dispute') return { kind, id: id as DisputeId };
  return null;
}

export function mapComplaintRow(row: ComplaintRow): ComplaintListItem {
  return {
    ref:
      row.kind === 'report'
        ? { kind: 'report', id: row.id as UserReportId }
        : { kind: 'dispute', id: row.id as DisputeId },
    myRole: row.my_role,
    status: complaintStatusGroup(row.status),
    outcome: (row.outcome as ReportOutcome | null) ?? null,
    reasonCodes: row.reason_codes ?? [],
    severity: row.severity,
    targetType: (row.target_type as ReportTargetType | null) ?? null,
    applicationId: (row.application_id as ApplicationId | null) ?? null,
    jobTitle: row.job_title,
    businessName: row.business_name,
    subjectLabel: row.subject_label,
    createdAt: row.created_at,
    resolvedAt: row.resolved_at,
    needsMyReply: row.needs_my_reply ?? false,
    lastActivityAt: row.last_activity_at,
  };
}

export function mapComplaintDetails(row: ComplaintDetailsRow): ComplaintDetails {
  return {
    ...mapComplaintRow(row),
    ownText: row.own_text,
    moderatorNote: row.moderator_note,
    thread: (row.thread ?? []).map(m => ({
      authorRole: m.author_role,
      body: m.body,
      createdAt: m.created_at,
    })),
    canReply: row.can_reply ?? false,
  };
}

export function splitComplaintsByRole(items: ComplaintListItem[]): {
  mine: ComplaintListItem[];
  against: ComplaintListItem[];
} {
  const byActivity = [...items].sort((a, b) => b.lastActivityAt.localeCompare(a.lastActivityAt));
  return {
    mine: byActivity.filter(i => i.myRole === 'reporter'),
    against: byActivity.filter(i => i.myRole === 'target'),
  };
}

export function complaintRefFromNotification(data: ComplaintNotificationData): ComplaintRef | null {
  if (data.complaintKind && data.complaintId)
    return complaintRef(data.complaintKind, data.complaintId);
  if (data.reportId) return complaintRef('report', data.reportId);
  if (data.disputeId) return complaintRef('dispute', data.disputeId);
  return null;
}

const REPORT_ERROR_KEYS: Record<string, string> = {
  REPORT_RATE_LIMIT: 'report.rateLimited',
  REPORT_TARGET_NOT_FOUND: 'report.targetGone',
};

export function reportSubmitErrorKey(error: unknown): string {
  if (typeof error !== 'object' || error === null) return 'report.error';
  const { code, message } = error as { code?: string; message?: string };
  if (code === '23505') return 'report.alreadyReported';
  return (message && REPORT_ERROR_KEYS[message]) ?? 'report.error';
}

export function complaintReasonKeys(item: ComplaintListItem): string[] {
  const prefix = item.ref.kind === 'report' ? 'report.reason' : 'disputes.category';
  return item.reasonCodes.map(code => `${prefix}.${code}`);
}

/** One-line title for a complaint; never names the reporter to the target. */
export function complaintTitle(item: ComplaintListItem, t: (key: string) => string): string {
  if (item.ref.kind === 'dispute') return item.jobTitle ?? t('complaints.about.shift');
  const scope = item.myRole === 'reporter' ? 'about' : 'aboutMe';
  const heading = t(`complaints.${scope}.${item.targetType ?? 'user'}`);
  const label = item.subjectLabel ?? item.jobTitle ?? item.businessName;
  return label ? `${heading}: ${label}` : heading;
}

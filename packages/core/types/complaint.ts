import type { ApplicationId, DisputeId, UserReportId } from './ids';
import type { ReportOutcome, ReportTargetType } from './userReport';

export type ComplaintKind = 'report' | 'dispute';

export type ComplaintRef =
  { kind: 'report'; id: UserReportId } | { kind: 'dispute'; id: DisputeId };

export type ComplaintRole = 'reporter' | 'target';

export type ComplaintStatusGroup = 'open' | 'in_review' | 'resolved' | 'dismissed';

export type ComplaintListItem = {
  ref: ComplaintRef;
  myRole: ComplaintRole;
  status: ComplaintStatusGroup;
  outcome: ReportOutcome | null;
  reasonCodes: string[];
  severity: string | null;
  targetType: ReportTargetType | null;
  applicationId: ApplicationId | null;
  jobTitle: string | null;
  businessName: string | null;
  subjectLabel: string | null;
  createdAt: string;
  resolvedAt: string | null;
  needsMyReply: boolean;
  lastActivityAt: string;
};

export type ComplaintThreadMessage = {
  authorRole: 'admin' | 'participant';
  body: string;
  createdAt: string;
};

export type ComplaintDetails = ComplaintListItem & {
  ownText: string | null;
  moderatorNote: string | null;
  thread: ComplaintThreadMessage[];
  canReply: boolean;
};

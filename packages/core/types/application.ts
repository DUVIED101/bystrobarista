import type { DisputeId } from './ids';
import type { Employment } from './employment';
import type { Job } from './job';

// Application Types
export type ApplicationStatus =
  'pending' | 'under_review' | 'accepted' | 'rejected' | 'withdrawn' | 'completed';

export type ShiftConfirmationStatus = 'pending' | 'confirmed' | 'declined' | 'no_response';

export type ShiftLifecycleStatus =
  'open' | 'under_review' | 'accepted' | 'in_progress' | 'completed';

export interface Application {
  id: string;
  jobId: string;
  baristaId: string;
  status: ApplicationStatus;
  coverLetter?: string;
  completedByBarista: boolean;
  completedByBusiness: boolean;
  completedAt?: string;
  createdViaOffer: boolean;
  createdAt: string;
  updatedAt: string;
  shiftConfirmationStatus?: ShiftConfirmationStatus;
  shiftConfirmationRequestedAt?: string;
  shiftConfirmationRespondedAt?: string;

  // Joined fields (from database queries)
  job?: Job;
  employment?: Employment; // Permanent hires only
  baristaEmail?: string; // For business view of applicants
  baristaProfile?: {
    firstName: string;
    lastName: string;
    avatarUrl?: string;
    bio?: string;
    equipmentExperience: string[];
    yearsOfExperience?: number;
  };
}

export interface CreateApplicationData {
  jobId: string;
  baristaId: string;
  coverLetter?: string;
}

export interface UpdateApplicationData {
  status?: ApplicationStatus;
  coverLetter?: string;
}

export interface ApplicationFilters {
  status?: ApplicationStatus;
  jobId?: string;
  baristaId?: string;
}

export type DisputeStatus = 'submitted' | 'under_review' | 'resolved' | 'dismissed';

export type DisputeSummary = {
  id: DisputeId;
  applicationId: string;
  categories: string[];
  severity: string;
  status: DisputeStatus;
  /** Moderator note meant for the viewer: the reply for the reporter, the note for the reportee. */
  resolutionNote?: string;
  createdAt: string;
  myRole: 'reporter' | 'reportee';
};

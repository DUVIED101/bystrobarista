import type { ComplaintStatusGroup } from '@bystrobarista/core/types';

export const COMPLAINT_STATUS_COLOR: Record<ComplaintStatusGroup, string> = {
  open: '#F59E0B',
  in_review: '#3B82F6',
  resolved: '#10B981',
  dismissed: '#6B7280',
};

export function formatComplaintDate(iso: string, language: string, withTime = false): string {
  return new Date(iso).toLocaleString(language === 'en' ? 'en-US' : 'ru-RU', {
    day: 'numeric',
    month: 'long',
    year: withTime ? undefined : 'numeric',
    hour: withTime ? '2-digit' : undefined,
    minute: withTime ? '2-digit' : undefined,
  });
}

import { supabase } from '../config/supabase';
import type { UserId } from '@bystrobarista/core/types/ids';
import type {
  NotificationPreferences,
  UpdateNotificationPreferences,
} from '@bystrobarista/core/types/notificationPreferences';

type PrefsRow = {
  user_id: string;
  new_message: boolean;
  application_accepted: boolean;
  application_rejected: boolean;
  new_application: boolean;
  application_withdrawn: boolean;
  shift_cancelled: boolean;
  new_review: boolean;
  conversation_started: boolean;
  job_offer_received: boolean;
  job_offer_accepted: boolean;
  job_offer_declined: boolean;
  work_completion_requested: boolean;
  work_completion_confirmed: boolean;
  employment_started: boolean;
  employment_ended: boolean;
  new_job_nearby?: boolean;
  response_reminders?: boolean;
  weekly_digest?: boolean;
  product_news?: boolean;
  updated_at: string;
};

const CAMEL_TO_SNAKE: Readonly<Record<keyof UpdateNotificationPreferences, keyof PrefsRow>> = {
  newMessage: 'new_message',
  applicationAccepted: 'application_accepted',
  applicationRejected: 'application_rejected',
  newApplication: 'new_application',
  applicationWithdrawn: 'application_withdrawn',
  shiftCancelled: 'shift_cancelled',
  newReview: 'new_review',
  conversationStarted: 'conversation_started',
  jobOfferReceived: 'job_offer_received',
  jobOfferAccepted: 'job_offer_accepted',
  jobOfferDeclined: 'job_offer_declined',
  workCompletionRequested: 'work_completion_requested',
  workCompletionConfirmed: 'work_completion_confirmed',
  employmentStarted: 'employment_started',
  employmentEnded: 'employment_ended',
  newJobNearby: 'new_job_nearby',
  responseReminders: 'response_reminders',
  weeklyDigest: 'weekly_digest',
  productNews: 'product_news',
};

export class NotificationPreferencesService {
  private static mapPrefs(db: PrefsRow): NotificationPreferences {
    return {
      userId: db.user_id as UserId,
      newMessage: db.new_message,
      applicationAccepted: db.application_accepted,
      applicationRejected: db.application_rejected,
      newApplication: db.new_application,
      applicationWithdrawn: db.application_withdrawn,
      shiftCancelled: db.shift_cancelled,
      newReview: db.new_review,
      conversationStarted: db.conversation_started,
      jobOfferReceived: db.job_offer_received,
      jobOfferAccepted: db.job_offer_accepted,
      jobOfferDeclined: db.job_offer_declined,
      workCompletionRequested: db.work_completion_requested,
      workCompletionConfirmed: db.work_completion_confirmed,
      employmentStarted: db.employment_started ?? true,
      employmentEnded: db.employment_ended ?? true,
      newJobNearby: db.new_job_nearby ?? true,
      responseReminders: db.response_reminders ?? true,
      weeklyDigest: db.weekly_digest ?? true,
      productNews: db.product_news ?? true,
      updatedAt: db.updated_at,
    };
  }

  static async getPreferences(userId: UserId): Promise<NotificationPreferences | null> {
    try {
      const { data, error } = await supabase
        .from('notification_preferences')
        .select('*')
        .eq('user_id', userId)
        .single();

      if (error) {
        if (error.code === 'PGRST116') {
          return null;
        }
        throw error;
      }

      return data ? this.mapPrefs(data as PrefsRow) : null;
    } catch (error) {
      console.error('Error in getPreferences:', error);
      throw error;
    }
  }

  static async upsertPreferences(
    userId: UserId,
    updates: UpdateNotificationPreferences
  ): Promise<NotificationPreferences> {
    try {
      const row: Record<string, unknown> = { user_id: userId };

      for (const key of Object.keys(updates) as Array<keyof UpdateNotificationPreferences>) {
        const value = updates[key];
        if (value !== undefined) {
          row[CAMEL_TO_SNAKE[key]] = value;
        }
      }

      const { data, error } = await supabase
        .from('notification_preferences')
        .upsert(row, { onConflict: 'user_id' })
        .select()
        .single();

      if (error) throw error;
      if (!data) throw new Error('Failed to upsert notification preferences');

      return this.mapPrefs(data as PrefsRow);
    } catch (error) {
      console.error('Error in upsertPreferences:', error);
      throw error;
    }
  }
}

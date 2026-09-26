import { supabase } from '../config/supabase';
import type {
  ApplicationId,
  ComplaintDetails,
  ComplaintListItem,
  ComplaintRef,
} from '@bystrobarista/core/types';
import {
  mapComplaintDetails,
  mapComplaintRow,
  type ComplaintDetailsRow,
  type ComplaintRow,
} from '@bystrobarista/core/utils/complaints';

/**
 * Complaints the caller filed or that were filed against them — user reports
 * and shift disputes together. Reads go through SECURITY DEFINER RPCs scoped
 * to auth.uid(), so the target never receives the reporter's identity or text.
 */
export class ComplaintService {
  static async listMine(): Promise<ComplaintListItem[]> {
    const { data, error } = await supabase.rpc('list_my_complaints');
    if (error) throw error;
    return ((data ?? []) as ComplaintRow[]).map(mapComplaintRow);
  }

  static async get(ref: ComplaintRef): Promise<ComplaintDetails | null> {
    const { data, error } = await supabase.rpc('get_my_complaint', {
      p_kind: ref.kind,
      p_id: ref.id,
    });
    if (error) throw error;
    return data ? mapComplaintDetails(data as ComplaintDetailsRow) : null;
  }

  static async reply(ref: ComplaintRef, body: string): Promise<void> {
    const { error } = await supabase.rpc('reply_to_complaint', {
      p_kind: ref.kind,
      p_id: ref.id,
      p_body: body,
    });
    if (error) throw error;
  }

  /** The dispute about this shift the caller is party to; their own filing wins. */
  static async findMyDisputeForApplication(
    applicationId: ApplicationId
  ): Promise<ComplaintRef | null> {
    const disputes = (await ComplaintService.listMine()).filter(
      c => c.ref.kind === 'dispute' && c.applicationId === applicationId
    );
    const own = disputes.find(c => c.myRole === 'reporter') ?? disputes[0];
    return own?.ref ?? null;
  }
}

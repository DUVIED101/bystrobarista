import React, { useEffect, useState } from 'react';
import { ActivityIndicator, StyleSheet } from 'react-native';
import type { NativeStackScreenProps } from '@react-navigation/native-stack';
import { COLORS } from '@bystrobarista/core/config/constants';
import { ComplaintService } from '@bystrobarista/core/services/ComplaintService';
import type { ApplicationId, ComplaintRef, DisputeId } from '@bystrobarista/core/types';
import { ComplaintDetailsView } from '../../components/complaints/ComplaintDetailsView';

type ParamList = {
  DisputeDetails: { applicationId?: string; disputeId?: string };
};

type Props = NativeStackScreenProps<ParamList, 'DisputeDetails'>;

export const DisputeDetailsScreen: React.FC<Props> = ({ route }) => {
  const { applicationId, disputeId } = route.params;
  const [complaintRef, setComplaintRef] = useState<ComplaintRef | null>(
    disputeId ? { kind: 'dispute', id: disputeId as DisputeId } : null
  );
  const [resolving, setResolving] = useState(!disputeId && !!applicationId);

  useEffect(() => {
    if (disputeId || !applicationId) return;
    let cancelled = false;
    const resolve = async () => {
      try {
        const ref = await ComplaintService.findMyDisputeForApplication(
          applicationId as ApplicationId
        );
        if (!cancelled) setComplaintRef(ref);
      } catch (error) {
        console.error('DisputeDetailsScreen: resolve failed', error);
      } finally {
        if (!cancelled) setResolving(false);
      }
    };
    resolve();
    return () => {
      cancelled = true;
    };
  }, [applicationId, disputeId]);

  if (resolving) {
    return <ActivityIndicator style={styles.loader} color={COLORS.primary} />;
  }
  return <ComplaintDetailsView complaintRef={complaintRef} />;
};

const styles = StyleSheet.create({
  loader: { flex: 1, justifyContent: 'center', backgroundColor: COLORS.background },
});

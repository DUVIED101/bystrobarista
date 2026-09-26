import React, { useLayoutEffect } from 'react';
import { useTranslation } from 'react-i18next';
import type { NativeStackScreenProps } from '@react-navigation/native-stack';
import { ComplaintDetailsView } from '../../components/complaints/ComplaintDetailsView';
import type { SettingsStackParamList } from '../../navigation/SettingsStack';

type Props = NativeStackScreenProps<SettingsStackParamList, 'ComplaintDetails'>;

export const ComplaintDetailsScreen: React.FC<Props> = ({ navigation, route }) => {
  const { t } = useTranslation();
  useLayoutEffect(() => {
    navigation.setOptions({ title: t('complaints.detailsTitle') });
  }, [navigation, t]);
  return <ComplaintDetailsView complaintRef={route.params} />;
};

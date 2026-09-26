import React from 'react';
import { createNativeStackNavigator } from '@react-navigation/native-stack';
import { COLORS } from '@bystrobarista/core/config/constants';
import { useTranslation } from 'react-i18next';
import type { ComplaintRef } from '@bystrobarista/core/types';

export type SettingsStackParamList = {
  SettingsHome: undefined;
  Language: undefined;
  ChangePassword: undefined;
  Notifications: undefined;
  DeleteAccount: undefined;
  Visibility: undefined;
  BlockedUsers: undefined;
  Documents: undefined;
  Terms: undefined;
  PrivacyPolicy: undefined;
  PersonalDataPolicy: undefined;
  DataConsent: undefined;
  Support: undefined;
  Complaints: { tab?: 'mine' | 'against'; open?: ComplaintRef } | undefined;
  ComplaintDetails: ComplaintRef;
  Diagnostic: undefined;
};

const Stack = createNativeStackNavigator<SettingsStackParamList>();

export const SettingsStack: React.FC = () => {
  const { t } = useTranslation();
  return (
    <Stack.Navigator
      screenOptions={{
        headerStyle: {
          backgroundColor: COLORS.background,
        },
        headerTintColor: COLORS.text,
        headerShadowVisible: false,
      }}>
      <Stack.Screen
        name="SettingsHome"
        getComponent={() => require('../screens/settings/SettingsScreen').SettingsScreen}
      />
      <Stack.Screen
        name="Language"
        getComponent={() => require('../screens/settings/LanguageScreen').LanguageScreen}
      />
      <Stack.Screen
        name="ChangePassword"
        getComponent={() =>
          require('../screens/settings/ChangePasswordScreen').ChangePasswordScreen
        }
      />
      <Stack.Screen
        name="Notifications"
        getComponent={() => require('../screens/settings/NotificationsScreen').NotificationsScreen}
      />
      <Stack.Screen
        name="DeleteAccount"
        getComponent={() => require('../screens/settings/DeleteAccountScreen').DeleteAccountScreen}
      />
      <Stack.Screen
        name="Visibility"
        getComponent={() => require('../screens/settings/VisibilityScreen').VisibilityScreen}
      />
      <Stack.Screen
        name="BlockedUsers"
        getComponent={() => require('../screens/settings/BlockedUsersScreen').BlockedUsersScreen}
      />
      <Stack.Screen
        name="Documents"
        getComponent={() => require('../screens/settings/DocumentsScreen').DocumentsScreen}
      />
      <Stack.Screen
        name="Terms"
        getComponent={() => require('../screens/settings/TermsScreen').TermsScreen}
      />
      <Stack.Screen
        name="PrivacyPolicy"
        getComponent={() => require('../screens/settings/PrivacyPolicyScreen').PrivacyPolicyScreen}
      />
      <Stack.Screen
        name="PersonalDataPolicy"
        getComponent={() =>
          require('../screens/settings/PersonalDataPolicyScreen').PersonalDataPolicyScreen
        }
      />
      <Stack.Screen
        name="DataConsent"
        getComponent={() => require('../screens/settings/DataConsentScreen').DataConsentScreen}
      />
      <Stack.Screen
        name="Support"
        getComponent={() => require('../screens/settings/SupportScreen').SupportScreen}
      />
      <Stack.Screen
        name="Complaints"
        getComponent={() => require('../screens/settings/ComplaintsScreen').ComplaintsScreen}
        options={{ title: t('complaints.title') }}
      />
      <Stack.Screen
        name="ComplaintDetails"
        getComponent={() =>
          require('../screens/settings/ComplaintDetailsScreen').ComplaintDetailsScreen
        }
        options={{ title: t('complaints.detailsTitle') }}
      />
      <Stack.Screen
        name="Diagnostic"
        getComponent={() => require('../screens/settings/DiagnosticScreen').DiagnosticScreen}
      />
    </Stack.Navigator>
  );
};

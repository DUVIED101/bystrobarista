import React, { useEffect } from 'react';
import { NavigationContainer } from '@react-navigation/native';
import { View, ActivityIndicator, StyleSheet } from 'react-native';
import { useAuthStore } from '@bystrobarista/core/stores/authStore';
import { AuthStack } from './AuthStack';
import { MainTabs } from './MainTabs';
import { flushPendingPushPayload, navigationRef } from './navigationRef';
import { BootstrapStack } from './BootstrapStack';
import { ConnectionErrorScreen } from '../screens/auth/ConnectionErrorScreen';
import { COLORS } from '@bystrobarista/core/config/constants';
import { ErrorBoundary } from '../components/ErrorBoundary';
import { ErrorToast } from '../components/ErrorToast';
import { AppUpdateBanner } from '../components/AppUpdateBanner';
import { AppUpdateRequiredScreen } from '../screens/AppUpdateRequiredScreen';
import { useAppUpdatePrompt } from '../hooks/useAppUpdatePrompt';
import { useWhatsNewStore } from '@bystrobarista/core/stores/whatsNewStore';

export const AppNavigator: React.FC = () => {
  const isAuthenticated = useAuthStore(s => s.isAuthenticated);
  const user = useAuthStore(s => s.user);
  const isLoading = useAuthStore(s => s.isLoading);
  const connectionError = useAuthStore(s => s.connectionError);
  const initialize = useAuthStore(s => s.initialize);
  const isSignedIn = isAuthenticated && Boolean(user?.consentAcceptedAt);
  const appUpdate = useAppUpdatePrompt(isSignedIn);
  const isWhatsNewShowing = useWhatsNewStore(s => s.status === 'visible');

  useEffect(() => {
    initialize();
  }, [initialize]);

  if (isLoading) {
    return (
      <View style={styles.loadingContainer}>
        <ActivityIndicator size="large" color={COLORS.primary} />
      </View>
    );
  }

  const renderRoot = () => {
    if (connectionError && !isAuthenticated) {
      return <ConnectionErrorScreen key="connection-error" />;
    }
    if (!isAuthenticated) {
      return <AuthStack key="unauthenticated" />;
    }
    // BootstrapStack is rendered whenever:
    //  • we have a session but no public.users row yet (brand new user); OR
    //  • the row exists but consent_accepted_at is still NULL.
    // The latter catches the case where a first-time OAuth user signed out
    // from the consent gate without accepting — on their next sign-in the
    // gate must reappear, otherwise OAuth would bypass consent entirely.
    if (!user || !user.consentAcceptedAt) {
      return <BootstrapStack key="bootstrap" />;
    }
    if (appUpdate.prompt === 'blocked') {
      return <AppUpdateRequiredScreen key="update-required" onUpdate={appUpdate.openStore} />;
    }
    return <MainTabs key="authenticated" />;
  };

  return (
    <NavigationContainer ref={navigationRef} onReady={flushPendingPushPayload}>
      <ErrorBoundary>{renderRoot()}</ErrorBoundary>
      <ErrorToast />
      <AppUpdateBanner
        visible={isSignedIn && appUpdate.prompt === 'soft' && !isWhatsNewShowing}
        onUpdate={appUpdate.openStore}
        onDismiss={appUpdate.dismissSoft}
      />
    </NavigationContainer>
  );
};

const styles = StyleSheet.create({
  loadingContainer: {
    flex: 1,
    justifyContent: 'center',
    alignItems: 'center',
    backgroundColor: COLORS.background,
  },
});

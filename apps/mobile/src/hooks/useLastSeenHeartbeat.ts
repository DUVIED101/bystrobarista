import { useEffect } from 'react';
import { AppState } from 'react-native';
import { useAuthStore } from '@bystrobarista/core/stores/authStore';
import { UserService } from '@bystrobarista/core/services/UserService';

// Marks the signed-in user as seen on launch and on every return to the
// foreground; the server keeps at most one write per 5 minutes.
export const useLastSeenHeartbeat = (): void => {
  const userId = useAuthStore(s => s.user?.id);

  useEffect(() => {
    if (!userId) return;
    void UserService.touchLastSeen();
    const sub = AppState.addEventListener('change', nextState => {
      if (nextState === 'active') void UserService.touchLastSeen();
    });
    return () => sub.remove();
  }, [userId]);
};

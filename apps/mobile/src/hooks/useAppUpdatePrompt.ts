import { useCallback, useEffect, useRef, useState } from 'react';
import { AppState, Linking, Platform } from 'react-native';
import AsyncStorage from '@react-native-async-storage/async-storage';
import { FeatureFlagService } from '@bystrobarista/core/services/FeatureFlagService';
import { APP_STORE_URL } from '@bystrobarista/core/config/appStore';
import { resolveAppUpdatePrompt, type AppUpdatePrompt } from '@bystrobarista/core/utils/appUpdate';
import { getAppBuild } from '../config/version';

const CHECK_INTERVAL_MS = 30 * 60 * 1000;
const LAST_SOFT_PROMPT_KEY = 'appUpdate.lastSoftPromptAt';

const readLastSoftPromptAt = async (): Promise<Date | null> => {
  try {
    const raw = await AsyncStorage.getItem(LAST_SOFT_PROMPT_KEY);
    if (!raw) return null;
    const date = new Date(raw);
    return Number.isNaN(date.getTime()) ? null : date;
  } catch (error) {
    console.warn('Error reading lastSoftPromptAt:', error);
    return null;
  }
};

const writeLastSoftPromptAt = async (date: Date): Promise<void> => {
  try {
    await AsyncStorage.setItem(LAST_SOFT_PROMPT_KEY, date.toISOString());
  } catch (error) {
    console.warn('Error writing lastSoftPromptAt:', error);
  }
};

export type AppUpdatePromptState = {
  prompt: AppUpdatePrompt;
  openStore: () => Promise<void>;
  dismissSoft: () => Promise<void>;
};

export const useAppUpdatePrompt = (enabled: boolean): AppUpdatePromptState => {
  const [prompt, setPrompt] = useState<AppUpdatePrompt>('none');
  const lastCheckAtRef = useRef<number | null>(null);
  const isActive = enabled && Platform.OS === 'ios';

  const check = useCallback(async (): Promise<void> => {
    const nowMs = Date.now();
    if (lastCheckAtRef.current !== null && nowMs - lastCheckAtRef.current < CHECK_INTERVAL_MS) {
      return;
    }
    lastCheckAtRef.current = nowMs;
    try {
      const [latestBuild, minBuild, lastSoftPromptAt] = await Promise.all([
        FeatureFlagService.getNumber('latest_ios_build'),
        FeatureFlagService.getNumber('min_ios_build'),
        readLastSoftPromptAt(),
      ]);
      setPrompt(
        resolveAppUpdatePrompt({
          currentBuild: getAppBuild(),
          latestBuild,
          minBuild,
          lastSoftPromptAt,
          now: new Date(),
        })
      );
    } catch (error) {
      // Keep the last known prompt so a network blip never unblocks a stale build.
      console.warn('Error checking app update flags:', error);
    }
  }, []);

  useEffect(() => {
    if (!isActive) {
      lastCheckAtRef.current = null;
      setPrompt('none');
      return;
    }
    void check();
    const sub = AppState.addEventListener('change', nextState => {
      if (nextState === 'active') void check();
    });
    return () => sub.remove();
  }, [isActive, check]);

  const dismissSoft = useCallback(async (): Promise<void> => {
    setPrompt(current => (current === 'soft' ? 'none' : current));
    await writeLastSoftPromptAt(new Date());
  }, []);

  const openStore = useCallback(async (): Promise<void> => {
    if (prompt === 'soft') await dismissSoft();
    try {
      await Linking.openURL(APP_STORE_URL);
    } catch (error) {
      console.error('Error opening App Store:', error);
    }
  }, [prompt, dismissSoft]);

  return { prompt, openStore, dismissSoft };
};

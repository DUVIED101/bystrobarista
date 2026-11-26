import React, { useCallback, useMemo, useState } from 'react';
import { StyleSheet, Switch, Text, TouchableOpacity, View } from 'react-native';
import { useTranslation } from 'react-i18next';
import { COLORS, RADII, SPACING } from '@bystrobarista/core/config/constants';
import { BaristaProfileService } from '@bystrobarista/core/services/BaristaProfileService';
import { mapAnyError } from '@bystrobarista/core/utils/errorHandler';
import {
  formatMissingFields,
  getProfileVisibility,
  type ProfileVisibilityInput,
} from '@bystrobarista/core/utils/profileVisibility';
import type { BaristaProfile } from '@bystrobarista/core/types/baristaProfile';
import { showErrorToast } from '../stores/errorToastStore';

type Props = {
  profile: ProfileVisibilityInput & Pick<BaristaProfile, 'userId'>;
  onEditProfile: () => void;
  onProfileUpdated: (profile: BaristaProfile) => void;
};

export const ProfileVisibilityBanner = React.memo<Props>(
  ({ profile, onEditProfile, onProfileUpdated }) => {
    const { t } = useTranslation();
    const [pendingLooking, setPendingLooking] = useState<boolean | null>(null);
    const isSaving = pendingLooking !== null;
    const visibility = useMemo(() => getProfileVisibility(profile), [profile]);

    const handleLookingChange = useCallback(
      async (next: boolean) => {
        setPendingLooking(next);
        try {
          const updated = await BaristaProfileService.updateProfile(profile.userId, {
            isActivelyLooking: next,
          });
          onProfileUpdated(updated);
        } catch (error) {
          console.error('Error updating isActivelyLooking:', error);
          showErrorToast(mapAnyError(error));
        } finally {
          setPendingLooking(null);
        }
      },
      [profile.userId, onProfileUpdated]
    );

    if (visibility.visible) return null;

    if (visibility.reasons.includes('not_looking')) {
      const toggleLabel = t('profileVisibility.notLooking.toggle');
      const isLooking = pendingLooking ?? profile.isActivelyLooking;
      return (
        <View style={styles.container} accessibilityRole="summary">
          <Text style={styles.title} accessibilityRole="header">
            {t('profileVisibility.notLooking.title')}
          </Text>
          <Text style={styles.body}>{t('profileVisibility.notLooking.body')}</Text>
          <View style={styles.toggleRow}>
            <Text style={styles.toggleLabel} importantForAccessibility="no">
              {toggleLabel}
            </Text>
            <Switch
              value={isLooking}
              onValueChange={handleLookingChange}
              disabled={isSaving}
              trackColor={{ true: COLORS.primary, false: COLORS.border }}
              accessibilityLabel={toggleLabel}
              accessibilityState={{ checked: isLooking, disabled: isSaving }}
            />
          </View>
        </View>
      );
    }

    // Feed-level profile fetches skip work experiences; don't claim they're missing.
    const missing =
      profile.workExperiences === undefined
        ? visibility.missing.filter(field => field !== 'workHistory')
        : visibility.missing;
    const fields = formatMissingFields(missing, key => t(key));
    return (
      <View style={styles.container} accessibilityRole="summary">
        <Text style={styles.title} accessibilityRole="header">
          {t('profileVisibility.belowThreshold.title')}
        </Text>
        <Text style={styles.body}>
          {fields
            ? t('profileVisibility.belowThreshold.body', { fields })
            : t('profileVisibility.belowThreshold.bodyGeneric')}
        </Text>
        <TouchableOpacity
          style={styles.cta}
          onPress={onEditProfile}
          accessibilityRole="button"
          accessibilityLabel={t('profileVisibility.belowThreshold.cta')}
          activeOpacity={0.7}>
          <Text style={styles.ctaText}>{t('profileVisibility.belowThreshold.cta')}</Text>
        </TouchableOpacity>
      </View>
    );
  }
);

ProfileVisibilityBanner.displayName = 'ProfileVisibilityBanner';

const BANNER_TEXT = '#92400E';

const styles = StyleSheet.create({
  container: {
    backgroundColor: '#FEF3C7',
    borderColor: '#FCD34D',
    borderWidth: 1,
    borderRadius: RADII.card,
    padding: SPACING.lg,
    marginHorizontal: SPACING.lg,
    marginTop: SPACING.md,
    gap: SPACING.sm,
  },
  title: {
    fontSize: 16,
    fontWeight: '600',
    color: BANNER_TEXT,
  },
  body: {
    fontSize: 14,
    lineHeight: 20,
    color: BANNER_TEXT,
  },
  toggleRow: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    gap: SPACING.md,
    marginTop: SPACING.xs,
  },
  toggleLabel: {
    flex: 1,
    fontSize: 15,
    fontWeight: '600',
    color: BANNER_TEXT,
  },
  cta: {
    alignSelf: 'flex-start',
    backgroundColor: COLORS.primary,
    borderRadius: RADII.pill,
    paddingVertical: SPACING.sm + 2,
    paddingHorizontal: SPACING.lg,
    minHeight: 44,
    justifyContent: 'center',
    marginTop: SPACING.xs,
  },
  ctaText: {
    fontSize: 15,
    fontWeight: '600',
    color: '#fff',
  },
});

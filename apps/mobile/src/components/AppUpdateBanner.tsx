import React from 'react';
import { Modal, StyleSheet, Text, TouchableOpacity, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { useTranslation } from 'react-i18next';
import { COLORS, RADII, SPACING } from '@bystrobarista/core/config/constants';

type Props = {
  visible: boolean;
  onUpdate: () => void;
  onDismiss: () => void;
};

export const AppUpdateBanner = React.memo<Props>(({ visible, onUpdate, onDismiss }) => {
  const { t } = useTranslation();
  const insets = useSafeAreaInsets();
  if (!visible) return null;

  return (
    <Modal visible transparent animationType="fade" onRequestClose={onDismiss}>
      <View style={styles.backdrop}>
        <View
          style={[styles.card, { marginBottom: Math.max(insets.bottom, SPACING.lg) }]}
          accessibilityViewIsModal
          testID="appUpdate.soft">
          <Text style={styles.title} accessibilityRole="header">
            {t('appUpdate.soft.title')}
          </Text>
          <Text style={styles.body}>{t('appUpdate.soft.body')}</Text>
          <TouchableOpacity
            style={styles.primaryButton}
            onPress={onUpdate}
            accessibilityRole="button"
            activeOpacity={0.8}
            testID="appUpdate.soft.cta">
            <Text style={styles.primaryText}>{t('appUpdate.soft.cta')}</Text>
          </TouchableOpacity>
          <TouchableOpacity
            style={styles.secondaryButton}
            onPress={onDismiss}
            accessibilityRole="button"
            activeOpacity={0.6}
            testID="appUpdate.soft.dismiss">
            <Text style={styles.secondaryText}>{t('appUpdate.soft.dismiss')}</Text>
          </TouchableOpacity>
        </View>
      </View>
    </Modal>
  );
});

AppUpdateBanner.displayName = 'AppUpdateBanner';

const styles = StyleSheet.create({
  backdrop: {
    flex: 1,
    justifyContent: 'flex-end',
    backgroundColor: 'rgba(0,0,0,0.35)',
    paddingHorizontal: SPACING.lg,
  },
  card: {
    backgroundColor: COLORS.background,
    borderRadius: RADII.card + 4,
    padding: SPACING.xl,
    gap: SPACING.sm,
  },
  title: {
    fontSize: 20,
    fontWeight: '700',
    color: COLORS.text,
  },
  body: {
    fontSize: 15,
    lineHeight: 21,
    color: COLORS.textSecondary,
    marginBottom: SPACING.sm,
  },
  primaryButton: {
    backgroundColor: COLORS.primary,
    borderRadius: RADII.input,
    minHeight: 50,
    paddingVertical: SPACING.md,
    alignItems: 'center',
    justifyContent: 'center',
  },
  primaryText: {
    fontSize: 17,
    fontWeight: '600',
    color: '#fff',
    textAlign: 'center',
  },
  secondaryButton: {
    minHeight: 44,
    paddingVertical: SPACING.sm,
    alignItems: 'center',
    justifyContent: 'center',
  },
  secondaryText: {
    fontSize: 16,
    fontWeight: '500',
    color: COLORS.primary,
    textAlign: 'center',
  },
});

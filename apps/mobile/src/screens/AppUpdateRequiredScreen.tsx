import React from 'react';
import { ScrollView, StyleSheet, Text, TouchableOpacity, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { useTranslation } from 'react-i18next';
import MaterialCommunityIcons from 'react-native-vector-icons/MaterialCommunityIcons';
import { COLORS, RADII, SPACING } from '@bystrobarista/core/config/constants';

type Props = {
  onUpdate: () => void;
};

export const AppUpdateRequiredScreen: React.FC<Props> = ({ onUpdate }) => {
  const { t } = useTranslation();
  return (
    <SafeAreaView style={styles.container} testID="appUpdate.required">
      <ScrollView contentContainerStyle={styles.content}>
        <View style={styles.iconWrap} importantForAccessibility="no-hide-descendants">
          <MaterialCommunityIcons name="cellphone-arrow-down" size={56} color={COLORS.primary} />
        </View>
        <Text style={styles.title} accessibilityRole="header">
          {t('appUpdate.blocked.title')}
        </Text>
        <Text style={styles.body}>{t('appUpdate.blocked.body')}</Text>
      </ScrollView>
      <View style={styles.footer}>
        <TouchableOpacity
          style={styles.button}
          onPress={onUpdate}
          accessibilityRole="button"
          activeOpacity={0.8}
          testID="appUpdate.required.cta">
          <Text style={styles.buttonText}>{t('appUpdate.blocked.cta')}</Text>
        </TouchableOpacity>
      </View>
    </SafeAreaView>
  );
};

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: COLORS.background,
  },
  content: {
    flexGrow: 1,
    justifyContent: 'center',
    alignItems: 'center',
    padding: SPACING.xl,
  },
  iconWrap: {
    marginBottom: SPACING.xl,
  },
  title: {
    fontSize: 24,
    fontWeight: '700',
    color: COLORS.text,
    textAlign: 'center',
    marginBottom: SPACING.md,
  },
  body: {
    fontSize: 16,
    lineHeight: 22,
    color: COLORS.textSecondary,
    textAlign: 'center',
  },
  footer: {
    paddingHorizontal: SPACING.xl,
    paddingBottom: SPACING.lg,
  },
  button: {
    backgroundColor: COLORS.primary,
    borderRadius: RADII.input,
    minHeight: 50,
    paddingVertical: SPACING.md,
    alignItems: 'center',
    justifyContent: 'center',
  },
  buttonText: {
    fontSize: 17,
    fontWeight: '600',
    color: '#fff',
    textAlign: 'center',
  },
});

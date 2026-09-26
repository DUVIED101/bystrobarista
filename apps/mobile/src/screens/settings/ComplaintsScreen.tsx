import React, { useCallback, useEffect, useLayoutEffect, useMemo, useState } from 'react';
import {
  ActivityIndicator,
  FlatList,
  RefreshControl,
  StyleSheet,
  Text,
  TouchableOpacity,
  View,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { useFocusEffect } from '@react-navigation/native';
import { useTranslation } from 'react-i18next';
import type { NativeStackScreenProps } from '@react-navigation/native-stack';
import { COLORS } from '@bystrobarista/core/config/constants';
import { ComplaintService } from '@bystrobarista/core/services/ComplaintService';
import type { ComplaintListItem, ComplaintRef } from '@bystrobarista/core/types';
import {
  complaintReasonKeys,
  complaintTitle,
  splitComplaintsByRole,
} from '@bystrobarista/core/utils/complaints';
import type { SettingsStackParamList } from '../../navigation/SettingsStack';
import {
  COMPLAINT_STATUS_COLOR,
  formatComplaintDate,
} from '../../components/complaints/complaintUi';
import { showErrorToast } from '../../stores/errorToastStore';

type Props = NativeStackScreenProps<SettingsStackParamList, 'Complaints'>;

type Tab = 'mine' | 'against';

type RowProps = {
  item: ComplaintListItem;
  onOpen: (ref: ComplaintRef) => void;
};

const ComplaintRow = React.memo<RowProps>(({ item, onOpen }) => {
  const { t, i18n } = useTranslation();
  const handlePress = useCallback(() => onOpen(item.ref), [onOpen, item.ref]);
  return (
    <TouchableOpacity
      style={styles.card}
      onPress={handlePress}
      activeOpacity={0.7}
      accessibilityRole="button">
      <View style={styles.cardHeader}>
        <View style={styles.typeChip}>
          <Text style={styles.typeChipText}>{t(`complaints.type.${item.ref.kind}`)}</Text>
        </View>
        <View
          style={[styles.statusBadge, { backgroundColor: COMPLAINT_STATUS_COLOR[item.status] }]}>
          <Text style={styles.statusText}>{t(`complaints.status.${item.status}`)}</Text>
        </View>
      </View>
      <Text style={styles.title} numberOfLines={2}>
        {complaintTitle(item, t)}
      </Text>
      {item.ref.kind === 'dispute' && item.businessName ? (
        <Text style={styles.subtitle} numberOfLines={1}>
          {item.businessName}
        </Text>
      ) : null}
      <Text style={styles.reasons} numberOfLines={2}>
        {complaintReasonKeys(item)
          .map(key => t(key))
          .join(', ')}
      </Text>
      <View style={styles.cardFooter}>
        <Text style={styles.date}>{formatComplaintDate(item.createdAt, i18n.language)}</Text>
        {item.needsMyReply ? (
          <View style={styles.replyBadge}>
            <Text style={styles.replyBadgeText}>{t('complaints.needsReply')}</Text>
          </View>
        ) : null}
      </View>
    </TouchableOpacity>
  );
});

export const ComplaintsScreen: React.FC<Props> = ({ navigation, route }) => {
  const { t } = useTranslation();
  const [tab, setTab] = useState<Tab>(route.params?.tab ?? 'mine');
  const [items, setItems] = useState<ComplaintListItem[]>([]);
  const [loading, setLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);

  // Opened from a profile screen the list is the only route in the Settings
  // stack, so back has to leave the stack instead of popping within it.
  useLayoutEffect(() => {
    navigation.setOptions({
      title: t('complaints.title'),
      headerLeft: () => (
        <TouchableOpacity
          onPress={() => {
            if (navigation.canGoBack()) navigation.goBack();
            else navigation.getParent()?.goBack();
          }}
          accessibilityRole="button"
          accessibilityLabel={t('common.back', { defaultValue: 'Назад' })}
          hitSlop={{ top: 12, bottom: 12, left: 12, right: 12 }}
          style={styles.headerBack}>
          <Text style={styles.headerBackText}>‹</Text>
        </TouchableOpacity>
      ),
    });
  }, [navigation, t]);

  useEffect(() => {
    if (route.params?.tab) setTab(route.params.tab);
  }, [route.params?.tab]);

  // A push opens the list first and then the complaint, so back returns here.
  useEffect(() => {
    const open = route.params?.open;
    if (!open) return;
    navigation.setParams({ open: undefined });
    navigation.navigate('ComplaintDetails', open);
  }, [navigation, route.params?.open]);

  const load = useCallback(async () => {
    try {
      setItems(await ComplaintService.listMine());
    } catch (error) {
      console.error('ComplaintsScreen: load failed', error);
      showErrorToast(t('complaints.errors.load'));
    } finally {
      setLoading(false);
      setRefreshing(false);
    }
  }, [t]);

  useFocusEffect(
    useCallback(() => {
      load();
    }, [load])
  );

  const { mine, against } = useMemo(() => splitComplaintsByRole(items), [items]);
  const visible = tab === 'mine' ? mine : against;

  const handleOpen = useCallback(
    (ref: ComplaintRef) => navigation.navigate('ComplaintDetails', ref),
    [navigation]
  );
  const renderItem = useCallback(
    ({ item }: { item: ComplaintListItem }) => <ComplaintRow item={item} onOpen={handleOpen} />,
    [handleOpen]
  );
  const handleRefresh = useCallback(() => {
    setRefreshing(true);
    load();
  }, [load]);

  const renderTab = (value: Tab, list: ComplaintListItem[]) => {
    const active = tab === value;
    const needsReply = list.some(i => i.needsMyReply);
    return (
      <TouchableOpacity
        style={[styles.tab, active && styles.tabActive]}
        onPress={() => setTab(value)}
        accessibilityRole="tab"
        accessibilityState={{ selected: active }}>
        <Text style={[styles.tabText, active && styles.tabTextActive]}>
          {t(`complaints.tabs.${value}`)}
          {list.length > 0 ? ` · ${list.length}` : ''}
        </Text>
        {needsReply ? <View style={styles.tabDot} /> : null}
      </TouchableOpacity>
    );
  };

  return (
    <SafeAreaView style={styles.container} edges={['bottom']}>
      <View style={styles.tabBar} accessibilityRole="tablist">
        {renderTab('mine', mine)}
        {renderTab('against', against)}
      </View>
      {loading ? (
        <ActivityIndicator style={styles.loader} color={COLORS.primary} />
      ) : (
        <FlatList
          data={visible}
          renderItem={renderItem}
          keyExtractor={item => `${item.ref.kind}-${item.ref.id}`}
          contentContainerStyle={visible.length === 0 ? styles.emptyList : styles.list}
          refreshControl={<RefreshControl refreshing={refreshing} onRefresh={handleRefresh} />}
          ListEmptyComponent={
            <View style={styles.emptyContainer}>
              <Text style={styles.emptyText}>{t(`complaints.empty.${tab}`)}</Text>
              <Text style={styles.emptyHint}>{t(`complaints.emptyHint.${tab}`)}</Text>
            </View>
          }
        />
      )}
    </SafeAreaView>
  );
};

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: COLORS.background },
  loader: { flex: 1, justifyContent: 'center' },
  headerBack: { paddingHorizontal: 4, paddingVertical: 2 },
  headerBackText: { fontSize: 28, color: COLORS.primary, lineHeight: 30 },
  tabBar: {
    flexDirection: 'row',
    borderBottomWidth: 1,
    borderBottomColor: COLORS.border,
    backgroundColor: COLORS.background,
  },
  tab: {
    flex: 1,
    flexDirection: 'row',
    justifyContent: 'center',
    alignItems: 'center',
    gap: 6,
    paddingVertical: 14,
    borderBottomWidth: 2,
    borderBottomColor: 'transparent',
  },
  tabActive: { borderBottomColor: COLORS.primary },
  tabText: { fontSize: 16, fontWeight: '500', color: COLORS.textSecondary },
  tabTextActive: { color: COLORS.primary, fontWeight: '600' },
  tabDot: { width: 8, height: 8, borderRadius: 4, backgroundColor: '#EF4444' },
  list: { padding: 16 },
  emptyList: { flexGrow: 1 },
  emptyContainer: { flex: 1, alignItems: 'center', justifyContent: 'center', padding: 32 },
  emptyText: { fontSize: 16, fontWeight: '600', color: COLORS.text, textAlign: 'center' },
  emptyHint: { fontSize: 14, color: COLORS.textSecondary, textAlign: 'center', marginTop: 8 },
  card: {
    backgroundColor: '#fff',
    borderRadius: 12,
    padding: 16,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: COLORS.border,
    marginBottom: 10,
  },
  cardHeader: { flexDirection: 'row', alignItems: 'center', gap: 8, marginBottom: 8 },
  typeChip: {
    paddingHorizontal: 8,
    paddingVertical: 3,
    borderRadius: 999,
    backgroundColor: COLORS.border,
  },
  typeChipText: { fontSize: 11, fontWeight: '600', color: COLORS.text },
  statusBadge: { paddingHorizontal: 8, paddingVertical: 3, borderRadius: 999 },
  statusText: { fontSize: 11, color: '#fff', fontWeight: '600' },
  title: { fontSize: 15, fontWeight: '600', color: COLORS.text, marginBottom: 2 },
  subtitle: { fontSize: 13, color: COLORS.textSecondary, marginBottom: 2 },
  reasons: { fontSize: 13, color: COLORS.text, marginTop: 2, marginBottom: 8 },
  cardFooter: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' },
  date: { fontSize: 12, color: COLORS.textSecondary },
  replyBadge: {
    paddingHorizontal: 8,
    paddingVertical: 3,
    borderRadius: 999,
    backgroundColor: '#FEE2E2',
  },
  replyBadgeText: { fontSize: 11, fontWeight: '600', color: '#B91C1C' },
});

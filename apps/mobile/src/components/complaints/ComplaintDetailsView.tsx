import React, { useCallback, useState } from 'react';
import {
  ActivityIndicator,
  KeyboardAvoidingView,
  Platform,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  TouchableOpacity,
  View,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { useFocusEffect } from '@react-navigation/native';
import { useHeaderHeight } from '@react-navigation/elements';
import { useTranslation } from 'react-i18next';
import { COLORS } from '@bystrobarista/core/config/constants';
import { ComplaintService } from '@bystrobarista/core/services/ComplaintService';
import type { ComplaintDetails, ComplaintRef } from '@bystrobarista/core/types';
import { complaintReasonKeys, complaintTitle } from '@bystrobarista/core/utils/complaints';
import { showErrorToast, showSuccessToast } from '../../stores/errorToastStore';
import { COMPLAINT_STATUS_COLOR, formatComplaintDate } from './complaintUi';

const REPLY_MAX = 2000;

const SEVERITY_COLOR: Record<string, string> = {
  warning: '#F59E0B',
  serious: '#FF8C00',
  critical: '#EF4444',
};

const REPLY_ERROR_KEYS: Record<string, string> = {
  COMPLAINT_REPLY_LIMIT: 'complaints.errors.replyLimit',
  COMPLAINT_CLOSED: 'complaints.errors.closed',
};

type Props = {
  complaintRef: ComplaintRef | null;
};

export const ComplaintDetailsView: React.FC<Props> = ({ complaintRef }) => {
  const { t, i18n } = useTranslation();
  const headerHeight = useHeaderHeight();
  const [complaint, setComplaint] = useState<ComplaintDetails | null>(null);
  const [loading, setLoading] = useState(true);
  const [reply, setReply] = useState('');
  const [sending, setSending] = useState(false);

  const load = useCallback(async () => {
    if (!complaintRef) {
      setLoading(false);
      return;
    }
    try {
      setComplaint(await ComplaintService.get(complaintRef));
    } catch (error) {
      console.error('ComplaintDetailsView: load failed', error);
      showErrorToast(t('complaints.errors.load'));
    } finally {
      setLoading(false);
    }
  }, [complaintRef, t]);

  useFocusEffect(
    useCallback(() => {
      load();
    }, [load])
  );

  const handleSend = useCallback(async () => {
    const body = reply.trim();
    if (!complaintRef || !body) return;
    setSending(true);
    try {
      await ComplaintService.reply(complaintRef, body);
      setReply('');
      showSuccessToast(t('complaints.thread.sent'));
      await load();
    } catch (error) {
      const message = (error as { message?: string })?.message ?? '';
      showErrorToast(t(REPLY_ERROR_KEYS[message] ?? 'complaints.errors.reply'));
    } finally {
      setSending(false);
    }
  }, [complaintRef, reply, t, load]);

  if (loading) {
    return (
      <SafeAreaView style={styles.container} edges={['bottom']}>
        <ActivityIndicator style={styles.loader} color={COLORS.primary} />
      </SafeAreaView>
    );
  }

  if (!complaint) {
    return (
      <SafeAreaView style={styles.container} edges={['bottom']}>
        <Text style={styles.notFound}>{t('complaints.notFound')}</Text>
      </SafeAreaView>
    );
  }

  const isTarget = complaint.myRole === 'target';
  const isOpen = complaint.status === 'open' || complaint.status === 'in_review';
  const lastIsMine = complaint.thread[complaint.thread.length - 1]?.authorRole === 'participant';
  const outcomeKey = complaint.outcome
    ? `complaints.${isTarget ? 'outcomeForTarget' : 'outcome'}.${complaint.outcome}`
    : null;

  return (
    <SafeAreaView style={styles.container} edges={['bottom']}>
      <KeyboardAvoidingView
        style={styles.flex}
        behavior={Platform.OS === 'ios' ? 'padding' : undefined}
        keyboardVerticalOffset={Platform.OS === 'ios' ? headerHeight : 0}>
        <ScrollView contentContainerStyle={styles.content} keyboardShouldPersistTaps="handled">
          <View style={styles.headerRow}>
            <View style={styles.typeChip}>
              <Text style={styles.typeChipText}>{t(`complaints.type.${complaint.ref.kind}`)}</Text>
            </View>
            <View
              style={[
                styles.statusBadge,
                { backgroundColor: COMPLAINT_STATUS_COLOR[complaint.status] },
              ]}>
              <Text style={styles.statusText}>{t(`complaints.status.${complaint.status}`)}</Text>
            </View>
          </View>
          <Text style={styles.title} accessibilityRole="header">
            {complaintTitle(complaint, t)}
          </Text>
          {complaint.ref.kind === 'dispute' && complaint.businessName ? (
            <Text style={styles.subtitle}>{complaint.businessName}</Text>
          ) : null}
          <Text style={styles.date}>
            {t('complaints.filedOn', {
              date: formatComplaintDate(complaint.createdAt, i18n.language),
            })}
          </Text>

          {isTarget ? (
            <View style={styles.infoBox}>
              <Text style={styles.infoText}>{t('complaints.anonymous')}</Text>
            </View>
          ) : null}

          <View style={styles.section}>
            <Text style={styles.label}>{t('complaints.section.reason')}</Text>
            <View style={styles.chipRow}>
              {complaintReasonKeys(complaint).map(key => (
                <View key={key} style={styles.chip}>
                  <Text style={styles.chipText}>{t(key)}</Text>
                </View>
              ))}
              {complaint.severity ? (
                <View
                  style={[
                    styles.chip,
                    { borderColor: SEVERITY_COLOR[complaint.severity] ?? COLORS.border },
                  ]}>
                  <Text style={styles.chipText}>
                    {t(`disputes.severity.${complaint.severity}`)}
                  </Text>
                </View>
              ) : null}
            </View>
          </View>

          {complaint.ownText ? (
            <View style={styles.section}>
              <Text style={styles.label}>{t('complaints.section.ownText')}</Text>
              <Text style={styles.bodyText}>{complaint.ownText}</Text>
            </View>
          ) : null}

          {outcomeKey || complaint.moderatorNote ? (
            <View style={styles.section}>
              <Text style={styles.label}>{t('complaints.section.decision')}</Text>
              {outcomeKey ? <Text style={styles.outcome}>{t(outcomeKey)}</Text> : null}
              {complaint.moderatorNote ? (
                <View style={styles.noteBox}>
                  <Text style={styles.noteLabel}>
                    {t(
                      isTarget
                        ? 'complaints.section.moderatorNote'
                        : 'complaints.section.moderatorReply'
                    )}
                  </Text>
                  <Text style={styles.bodyText}>{complaint.moderatorNote}</Text>
                </View>
              ) : null}
            </View>
          ) : isOpen ? (
            <View style={styles.infoBox}>
              <Text style={styles.infoText}>{t('disputes.pendingNote')}</Text>
            </View>
          ) : null}

          {complaint.thread.length > 0 ? (
            <View style={styles.section}>
              <Text style={styles.label}>{t('complaints.thread.title')}</Text>
              {complaint.thread.map((message, index) => {
                const mine = message.authorRole === 'participant';
                return (
                  <View
                    key={`${message.createdAt}-${index}`}
                    style={[styles.bubble, mine ? styles.bubbleMine : styles.bubbleAdmin]}>
                    <Text style={styles.bubbleAuthor}>
                      {mine ? t('complaints.thread.you') : t('complaints.thread.moderator')}
                    </Text>
                    <Text style={styles.bubbleText}>{message.body}</Text>
                    <Text style={styles.bubbleDate}>
                      {formatComplaintDate(message.createdAt, i18n.language, true)}
                    </Text>
                  </View>
                );
              })}
              {!complaint.canReply ? (
                <Text style={styles.threadHint}>
                  {isOpen ? t('complaints.thread.waiting') : t('complaints.thread.closed')}
                </Text>
              ) : lastIsMine ? (
                <Text style={styles.threadHint}>{t('complaints.thread.waiting')}</Text>
              ) : null}
            </View>
          ) : null}
        </ScrollView>

        {complaint.canReply ? (
          <View style={styles.composer}>
            <TextInput
              style={styles.input}
              value={reply}
              onChangeText={setReply}
              placeholder={t('complaints.thread.placeholder')}
              placeholderTextColor={COLORS.textSecondary}
              multiline
              maxLength={REPLY_MAX}
              accessibilityLabel={t('complaints.thread.placeholder')}
            />
            <TouchableOpacity
              style={[styles.sendButton, (!reply.trim() || sending) && styles.sendDisabled]}
              onPress={handleSend}
              disabled={!reply.trim() || sending}
              accessibilityRole="button"
              accessibilityLabel={t('complaints.thread.send')}>
              {sending ? (
                <ActivityIndicator color="#fff" />
              ) : (
                <Text style={styles.sendText}>{t('complaints.thread.send')}</Text>
              )}
            </TouchableOpacity>
          </View>
        ) : null}
      </KeyboardAvoidingView>
    </SafeAreaView>
  );
};

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: COLORS.background },
  flex: { flex: 1 },
  loader: { flex: 1, justifyContent: 'center' },
  notFound: { flex: 1, textAlign: 'center', marginTop: 48, color: COLORS.textSecondary },
  content: { padding: 20 },
  headerRow: { flexDirection: 'row', alignItems: 'center', gap: 8, marginBottom: 12 },
  typeChip: {
    paddingHorizontal: 10,
    paddingVertical: 4,
    borderRadius: 999,
    backgroundColor: COLORS.border,
  },
  typeChipText: { fontSize: 12, fontWeight: '600', color: COLORS.text },
  statusBadge: { paddingHorizontal: 10, paddingVertical: 4, borderRadius: 999 },
  statusText: { fontSize: 12, color: '#fff', fontWeight: '600' },
  title: { fontSize: 20, fontWeight: '700', color: COLORS.text, marginBottom: 4 },
  subtitle: { fontSize: 15, color: COLORS.textSecondary, marginBottom: 4 },
  date: { fontSize: 13, color: COLORS.textSecondary, marginBottom: 16 },
  section: { marginBottom: 20 },
  label: { fontSize: 13, fontWeight: '600', color: COLORS.textSecondary, marginBottom: 8 },
  chipRow: { flexDirection: 'row', flexWrap: 'wrap', gap: 8 },
  chip: {
    paddingHorizontal: 12,
    paddingVertical: 6,
    borderRadius: 20,
    borderWidth: 1.5,
    borderColor: COLORS.border,
    backgroundColor: '#fff',
  },
  chipText: { fontSize: 13, color: COLORS.text },
  bodyText: { fontSize: 15, color: COLORS.text, lineHeight: 22 },
  outcome: { fontSize: 15, fontWeight: '600', color: COLORS.text, marginBottom: 8 },
  noteBox: { backgroundColor: '#F3F4F6', borderRadius: 10, padding: 12 },
  noteLabel: { fontSize: 12, fontWeight: '600', color: COLORS.textSecondary, marginBottom: 4 },
  infoBox: { backgroundColor: '#EFF6FF', borderRadius: 10, padding: 14, marginBottom: 20 },
  infoText: { fontSize: 14, color: '#1D4ED8', lineHeight: 20 },
  bubble: { borderRadius: 12, padding: 12, marginBottom: 8, maxWidth: '88%' },
  bubbleAdmin: { backgroundColor: '#F3F4F6', alignSelf: 'flex-start' },
  bubbleMine: { backgroundColor: '#FEF3C7', alignSelf: 'flex-end' },
  bubbleAuthor: { fontSize: 12, fontWeight: '600', color: COLORS.textSecondary, marginBottom: 2 },
  bubbleText: { fontSize: 15, color: COLORS.text, lineHeight: 21 },
  bubbleDate: { fontSize: 11, color: COLORS.textSecondary, marginTop: 4 },
  threadHint: { fontSize: 13, color: COLORS.textSecondary, marginTop: 4 },
  composer: {
    flexDirection: 'row',
    alignItems: 'flex-end',
    gap: 8,
    paddingHorizontal: 12,
    paddingVertical: 8,
    borderTopWidth: StyleSheet.hairlineWidth,
    borderTopColor: COLORS.border,
    backgroundColor: COLORS.background,
  },
  input: {
    flex: 1,
    minHeight: 44,
    maxHeight: 140,
    borderWidth: 1,
    borderColor: COLORS.border,
    borderRadius: 12,
    paddingHorizontal: 12,
    paddingTop: 12,
    paddingBottom: 12,
    fontSize: 15,
    color: COLORS.text,
    backgroundColor: '#fff',
  },
  sendButton: {
    minHeight: 44,
    paddingHorizontal: 16,
    borderRadius: 12,
    backgroundColor: COLORS.primary,
    alignItems: 'center',
    justifyContent: 'center',
  },
  sendDisabled: { opacity: 0.5 },
  sendText: { color: '#fff', fontSize: 15, fontWeight: '600' },
});

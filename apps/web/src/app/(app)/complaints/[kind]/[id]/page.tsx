"use client";

import Link from "next/link";
import { useParams } from "next/navigation";
import React, { useState } from "react";
import { useTranslation } from "react-i18next";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { getPlatform } from "@bystrobarista/core/platform";
import { ComplaintService } from "@bystrobarista/core/services/ComplaintService";
import type {
  ComplaintRef,
  DisputeId,
  UserReportId,
} from "@bystrobarista/core/types";
import {
  complaintReasonKeys,
  complaintTitle,
} from "@bystrobarista/core/utils/complaints";
import {
  COMPLAINT_SEVERITY_BORDER,
  COMPLAINT_STATUS_BADGE,
} from "@/lib/complaintUi";

const REPLY_MAX = 2000;

const REPLY_ERROR_KEYS: Record<string, string> = {
  COMPLAINT_REPLY_LIMIT: "complaints.errors.replyLimit",
  COMPLAINT_CLOSED: "complaints.errors.closed",
};

function refFromParams(kind: string, id: string): ComplaintRef | null {
  if (kind === "report") return { kind, id: id as UserReportId };
  if (kind === "dispute") return { kind, id: id as DisputeId };
  return null;
}

// One complaint of the viewer: summary, decision and the thread with the
// moderator. The target never sees the reporter or the reporter's text.
export default function ComplaintDetailsPage(): React.JSX.Element {
  const { t, i18n } = useTranslation();
  const locale = i18n.language === "ru" ? "ru-RU" : "en-US";
  const params = useParams<{ kind: string; id: string }>();
  const ref = refFromParams(params.kind, params.id);
  const queryClient = useQueryClient();
  const [reply, setReply] = useState("");

  const complaintQuery = useQuery({
    queryKey: ["complaints", "byId", params.kind, params.id],
    queryFn: () => (ref ? ComplaintService.get(ref) : null),
  });

  const replyMutation = useMutation({
    mutationFn: (body: string) =>
      ComplaintService.reply(ref as ComplaintRef, body),
    onSuccess: () => {
      setReply("");
      void queryClient.invalidateQueries({ queryKey: ["complaints"] });
    },
    onError: (error) => {
      const message = (error as { message?: string })?.message ?? "";
      getPlatform().alert.show(
        t(REPLY_ERROR_KEYS[message] ?? "complaints.errors.reply"),
        "",
      );
    },
  });

  if (complaintQuery.isPending) {
    return (
      <div className="mx-auto h-64 max-w-2xl animate-pulse rounded-card bg-bg-secondary" />
    );
  }

  const complaint = complaintQuery.data;
  if (!complaint) {
    return (
      <p className="py-16 text-center text-ink-secondary">
        {t("complaints.notFound")}
      </p>
    );
  }

  const isTarget = complaint.myRole === "target";
  const isOpen =
    complaint.status === "open" || complaint.status === "in_review";
  const lastIsMine =
    complaint.thread[complaint.thread.length - 1]?.authorRole === "participant";
  const outcomeKey = complaint.outcome
    ? `complaints.${isTarget ? "outcomeForTarget" : "outcome"}.${complaint.outcome}`
    : null;
  const formatDate = (iso: string, withTime = false): string =>
    new Date(iso).toLocaleString(locale, {
      day: "numeric",
      month: "long",
      year: withTime ? undefined : "numeric",
      hour: withTime ? "2-digit" : undefined,
      minute: withTime ? "2-digit" : undefined,
    });

  return (
    <div className="mx-auto max-w-2xl pb-10">
      <Link
        href={`/complaints?tab=${isTarget ? "against" : "mine"}`}
        className="mb-3 inline-block text-sm font-medium text-primary"
      >
        ← {t("complaints.title")}
      </Link>

      <div className="mb-3 flex items-center gap-2">
        <span className="rounded-chip bg-bg-secondary px-2.5 py-1 text-xs font-semibold">
          {t(`complaints.type.${complaint.ref.kind}`)}
        </span>
        <span
          className={`rounded-chip px-2.5 py-1 text-xs font-semibold text-white ${COMPLAINT_STATUS_BADGE[complaint.status]}`}
        >
          {t(`complaints.status.${complaint.status}`)}
        </span>
      </div>
      <h1 className="text-2xl font-bold">{complaintTitle(complaint, t)}</h1>
      {complaint.ref.kind === "dispute" && complaint.businessName && (
        <p className="text-ink-secondary">{complaint.businessName}</p>
      )}
      <p className="mb-5 mt-1 text-sm text-ink-secondary">
        {t("complaints.filedOn", { date: formatDate(complaint.createdAt) })}
      </p>

      {isTarget && (
        <p className="mb-5 rounded-card bg-[#EFF6FF] p-3.5 text-sm text-[#1D4ED8]">
          {t("complaints.anonymous")}
        </p>
      )}

      <section className="mb-6">
        <h2 className="mb-2 text-sm font-semibold text-ink-secondary">
          {t("complaints.section.reason")}
        </h2>
        <div className="flex flex-wrap gap-2">
          {complaintReasonKeys(complaint).map((key) => (
            <span
              key={key}
              className="rounded-chip bg-bg-secondary px-3 py-1.5 text-sm"
            >
              {t(key)}
            </span>
          ))}
          {complaint.severity && (
            <span
              className={`rounded-chip border-2 px-3 py-1 text-sm ${COMPLAINT_SEVERITY_BORDER[complaint.severity] ?? "border-line"}`}
            >
              {t(`disputes.severity.${complaint.severity}`)}
            </span>
          )}
        </div>
      </section>

      {complaint.ownText && (
        <section className="mb-6">
          <h2 className="mb-2 text-sm font-semibold text-ink-secondary">
            {t("complaints.section.ownText")}
          </h2>
          <p className="whitespace-pre-wrap">{complaint.ownText}</p>
        </section>
      )}

      {outcomeKey || complaint.moderatorNote ? (
        <section className="mb-6">
          <h2 className="mb-2 text-sm font-semibold text-ink-secondary">
            {t("complaints.section.decision")}
          </h2>
          {outcomeKey && <p className="mb-2 font-semibold">{t(outcomeKey)}</p>}
          {complaint.moderatorNote && (
            <div className="rounded-card bg-bg-secondary p-3">
              <p className="mb-1 text-xs font-semibold text-ink-secondary">
                {t(
                  isTarget
                    ? "complaints.section.moderatorNote"
                    : "complaints.section.moderatorReply",
                )}
              </p>
              <p className="whitespace-pre-wrap">{complaint.moderatorNote}</p>
            </div>
          )}
        </section>
      ) : (
        isOpen && (
          <p className="mb-6 rounded-card bg-[#EFF6FF] p-3.5 text-sm text-[#1D4ED8]">
            {t("disputes.pendingNote")}
          </p>
        )
      )}

      {complaint.thread.length > 0 && (
        <section className="mb-4">
          <h2 className="mb-2 text-sm font-semibold text-ink-secondary">
            {t("complaints.thread.title")}
          </h2>
          <div className="flex flex-col gap-2">
            {complaint.thread.map((message, index) => {
              const mine = message.authorRole === "participant";
              return (
                <div
                  key={`${message.createdAt}-${index}`}
                  className={`max-w-[88%] rounded-card p-3 ${
                    mine
                      ? "self-end bg-[#FEF3C7]"
                      : "self-start bg-bg-secondary"
                  }`}
                >
                  <p className="text-xs font-semibold text-ink-secondary">
                    {mine
                      ? t("complaints.thread.you")
                      : t("complaints.thread.moderator")}
                  </p>
                  <p className="whitespace-pre-wrap">{message.body}</p>
                  <p className="mt-1 text-[11px] text-ink-secondary">
                    {formatDate(message.createdAt, true)}
                  </p>
                </div>
              );
            })}
          </div>
          {(!complaint.canReply || lastIsMine) && (
            <p className="mt-2 text-sm text-ink-secondary">
              {isOpen
                ? t("complaints.thread.waiting")
                : t("complaints.thread.closed")}
            </p>
          )}
        </section>
      )}

      {complaint.canReply && (
        <form
          className="flex items-end gap-2"
          onSubmit={(e) => {
            e.preventDefault();
            const body = reply.trim();
            if (body) replyMutation.mutate(body);
          }}
        >
          <textarea
            value={reply}
            onChange={(e) => setReply(e.target.value)}
            maxLength={REPLY_MAX}
            rows={3}
            placeholder={t("complaints.thread.placeholder")}
            aria-label={t("complaints.thread.placeholder")}
            className="min-h-[44px] flex-1 rounded-input border border-line p-2.5 text-sm"
          />
          <button
            type="submit"
            disabled={!reply.trim() || replyMutation.isPending}
            className="min-h-[44px] rounded-input bg-primary px-4 text-sm font-semibold text-white disabled:opacity-50"
          >
            {t("complaints.thread.send")}
          </button>
        </form>
      )}
    </div>
  );
}

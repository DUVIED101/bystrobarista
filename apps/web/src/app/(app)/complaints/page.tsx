"use client";

import Link from "next/link";
import { useRouter, useSearchParams } from "next/navigation";
import React, { Suspense, useMemo } from "react";
import { useTranslation } from "react-i18next";
import { useQuery } from "@tanstack/react-query";
import { ComplaintService } from "@bystrobarista/core/services/ComplaintService";
import { useAuthStore } from "@bystrobarista/core/stores/authStore";
import type { ComplaintListItem } from "@bystrobarista/core/types";
import {
  complaintReasonKeys,
  complaintTitle,
  splitComplaintsByRole,
} from "@bystrobarista/core/utils/complaints";
import { COMPLAINT_STATUS_BADGE } from "@/lib/complaintUi";
import { formatDateOnly } from "@/lib/dates";

type Tab = "mine" | "against";

function ComplaintRow({
  item,
  locale,
}: {
  item: ComplaintListItem;
  locale: string;
}): React.JSX.Element {
  const { t } = useTranslation();
  return (
    <Link
      href={`/complaints/${item.ref.kind}/${item.ref.id}`}
      className="mb-2 block rounded-card border border-line bg-white p-3 hover:border-primary/40"
    >
      <div className="mb-1.5 flex items-center gap-2">
        <span className="rounded-chip bg-bg-secondary px-2 py-0.5 text-[11px] font-semibold">
          {t(`complaints.type.${item.ref.kind}`)}
        </span>
        <span
          className={`rounded-chip px-2 py-0.5 text-[11px] font-semibold text-white ${COMPLAINT_STATUS_BADGE[item.status]}`}
        >
          {t(`complaints.status.${item.status}`)}
        </span>
        {item.needsMyReply && (
          <span className="rounded-chip bg-error/10 px-2 py-0.5 text-[11px] font-semibold text-error">
            {t("complaints.needsReply")}
          </span>
        )}
      </div>
      <p className="text-sm font-semibold">{complaintTitle(item, t)}</p>
      {item.ref.kind === "dispute" && item.businessName && (
        <p className="truncate text-xs text-ink-secondary">
          {item.businessName}
        </p>
      )}
      <p className="mt-0.5 text-xs">
        {complaintReasonKeys(item)
          .map((key) => t(key))
          .join(", ")}
      </p>
      <p className="mt-0.5 text-[11px] text-ink-secondary">
        {formatDateOnly(item.createdAt, locale, {
          day: "numeric",
          month: "long",
          year: "numeric",
        })}
      </p>
    </Link>
  );
}

function ComplaintsContent(): React.JSX.Element {
  const { t, i18n } = useTranslation();
  const locale = i18n.language === "ru" ? "ru-RU" : "en-US";
  const router = useRouter();
  const searchParams = useSearchParams();
  const tab: Tab = searchParams.get("tab") === "against" ? "against" : "mine";
  const userId = useAuthStore((s) => s.user?.id);

  const complaintsQuery = useQuery({
    queryKey: ["complaints", "mine", userId],
    queryFn: () => ComplaintService.listMine(),
    enabled: Boolean(userId),
  });
  const { mine, against } = useMemo(
    () => splitComplaintsByRole(complaintsQuery.data ?? []),
    [complaintsQuery.data],
  );
  const visible = tab === "mine" ? mine : against;

  const tabButton = (value: Tab, list: ComplaintListItem[]) => {
    const active = tab === value;
    return (
      <button
        type="button"
        role="tab"
        aria-selected={active}
        onClick={() => router.replace(`/complaints?tab=${value}`)}
        className={`flex flex-1 items-center justify-center gap-1.5 border-b-2 py-3 text-sm ${
          active
            ? "border-primary font-semibold text-primary"
            : "border-transparent font-medium text-ink-secondary"
        }`}
      >
        {t(`complaints.tabs.${value}`)}
        {list.length > 0 ? ` · ${list.length}` : ""}
        {list.some((i) => i.needsMyReply) && (
          <span className="h-2 w-2 rounded-full bg-error" />
        )}
      </button>
    );
  };

  return (
    <div className="mx-auto max-w-2xl">
      <h1 className="mb-4 text-2xl font-bold">{t("complaints.title")}</h1>
      <div role="tablist" className="mb-4 flex border-b border-line">
        {tabButton("mine", mine)}
        {tabButton("against", against)}
      </div>

      {complaintsQuery.isPending &&
        Array.from({ length: 3 }).map((_, i) => (
          <div
            key={i}
            className="mb-2 h-24 animate-pulse rounded-card border border-line bg-bg-secondary"
          />
        ))}
      {complaintsQuery.isError && (
        <p className="py-12 text-center text-sm text-error">
          {t("complaints.errors.load")}
        </p>
      )}
      {complaintsQuery.isSuccess && visible.length === 0 && (
        <div className="py-12 text-center">
          <p className="font-semibold">{t(`complaints.empty.${tab}`)}</p>
          <p className="mt-2 text-sm text-ink-secondary">
            {t(`complaints.emptyHint.${tab}`)}
          </p>
        </div>
      )}
      {visible.map((item) => (
        <ComplaintRow
          key={`${item.ref.kind}-${item.ref.id}`}
          item={item}
          locale={locale}
        />
      ))}
    </div>
  );
}

// «Мои жалобы» and «Жалобы на меня»: user reports and shift disputes together.
export default function ComplaintsPage(): React.JSX.Element {
  return (
    <Suspense fallback={null}>
      <ComplaintsContent />
    </Suspense>
  );
}

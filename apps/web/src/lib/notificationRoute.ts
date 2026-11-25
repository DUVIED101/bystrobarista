import type { useRouter } from "next/navigation";
import type {
  Notification,
  NotificationData,
  NotificationKind,
} from "@bystrobarista/core/types/notification";
import { complaintRefFromNotification } from "@bystrobarista/core/utils/complaints";
import { safeExternalUrl } from "@/lib/safeUrl";

export type RoutableNotification = Pick<Notification, "kind"> & {
  data: Partial<NotificationData>;
};

export type NotificationTarget =
  { kind: "internal"; href: string } | { kind: "external"; url: string };

// Web twin of mobile's dispatchPayload (navigationRef.ts): maps a notification
// (feed row or push payload) to the route its tap should open, branched on
// account type exactly like the RN tab dispatch. Falls back to the role's home
// feed when IDs are missing. `action` carries a notification action button
// (job offer accept/decline) through to the offer page.
export const notificationHref = (
  notification: RoutableNotification,
  accountType: "barista" | "business",
  action?: "accepted" | "declined",
): string => {
  const kind: NotificationKind = notification.kind;
  const data = notification.data;
  const isBusiness = accountType === "business";
  const home = isBusiness ? "/dashboard" : "/jobs";
  const applicants = data.jobId ? `/jobs/${data.jobId}/applicants` : home;

  switch (kind) {
    case "new_message":
    case "conversation_started":
      return data.conversationId ? `/chats/${data.conversationId}` : "/chats";
    case "job_offer_received":
      if (!data.offerId) return home;
      return action
        ? `/offers/${data.offerId}?action=${action}`
        : `/offers/${data.offerId}`;
    case "job_offer_accepted":
    case "job_offer_declined":
    case "new_application":
    case "application_withdrawn":
    case "shift_confirmed":
    case "shift_declined":
      return isBusiness ? applicants : home;
    case "application_accepted":
    case "application_rejected":
    case "work_completion_requested":
    case "work_completion_confirmed":
    case "shift_cancelled":
      return isBusiness ? applicants : "/applications";
    case "new_review":
      return "/profile";
    case "job_start_reminder":
    case "shift_reminder_24h":
    case "shift_reminder_3h":
    case "employment_started":
    case "employment_start_due":
    case "employment_end_requested":
    case "employment_ended":
      if (isBusiness) return applicants;
      return data.applicationId
        ? `/applications/${data.applicationId}`
        : "/applications";
    case "shift_confirmation_required":
      return data.applicationId
        ? `/applications/${data.applicationId}`
        : "/applications";
    case "shift_no_response_alert": {
      if (!data.applicationId) return "/shift-alerts";
      const params = new URLSearchParams({ applicationId: data.applicationId });
      if (data.jobTitle) params.set("jobTitle", data.jobTitle);
      if (data.shiftStartIso) params.set("shiftStart", data.shiftStartIso);
      return `/shift-alerts?${params.toString()}`;
    }
    case "dispute_filed":
    case "report_resolved":
    case "complaint_info_requested":
    case "complaint_resolved": {
      const ref = complaintRefFromNotification(data);
      return ref ? `/complaints/${ref.kind}/${ref.id}` : "/complaints";
    }
    case "admin_dm":
    case "broadcast":
    case "app_update":
      return "/notifications";
    case "new_job_nearby":
      return data.jobId ? `/jobs/${data.jobId}` : "/jobs";
    case "weekly_digest":
    case "recurring_broadcast":
      return isBusiness ? "/baristas" : "/jobs";
    case "application_reminder":
      return isBusiness ? applicants : "/applications";
    case "application_expired":
      return "/jobs";
    case "job_offer_reminder":
      return data.offerId ? `/offers/${data.offerId}` : "/jobs";
    case "job_offer_expired":
      return "/baristas";
    case "profile_hidden":
      return "/profile/edit";
    default:
      return home;
  }
};

// app_update may carry an App Store link, which must not go through Next's
// router. Every tap handler should resolve a target and hand it to
// openNotificationTarget; notificationHref stays internal-only for callers
// that compare paths.
export const notificationTarget = (
  notification: RoutableNotification,
  accountType: "barista" | "business",
  action?: "accepted" | "declined",
): NotificationTarget => {
  if (notification.kind === "app_update") {
    const storeUrl = notification.data.storeUrl;
    const url = storeUrl?.startsWith("https://")
      ? safeExternalUrl(storeUrl)
      : null;
    if (url) return { kind: "external", url };
  }
  return {
    kind: "internal",
    href: notificationHref(notification, accountType, action),
  };
};

export const openNotificationTarget = (
  router: Pick<ReturnType<typeof useRouter>, "push">,
  target: NotificationTarget,
): void => {
  if (target.kind === "external") {
    window.open(target.url, "_blank", "noopener,noreferrer");
    return;
  }
  router.push(target.href);
};

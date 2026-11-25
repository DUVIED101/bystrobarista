import type { TFunction } from "i18next";
import type { ApplicationStatus } from "@bystrobarista/core/types/application";

export const APPLICATION_BADGE: Record<ApplicationStatus, string> = {
  pending: "bg-[#F59E0B]",
  under_review: "bg-[#F59E0B]",
  accepted: "bg-[#10B981]",
  rejected: "bg-[#EF4444]",
  withdrawn: "bg-[#6B7280]",
  expired: "bg-[#6B7280]",
  completed: "bg-[#6B7280]",
};

export const applicationStatusLabel = (
  status: ApplicationStatus,
  t: TFunction,
): string => {
  switch (status) {
    case "pending":
      return t("applications.status.pending");
    case "under_review":
      return t("applications.status.underReview");
    case "accepted":
      return t("applications.status.accepted");
    case "rejected":
      return t("applications.status.rejected");
    case "withdrawn":
      return t("applications.status.withdrawn");
    case "expired":
      return t("applications.status.expired");
    case "completed":
      return t("applications.status.completed");
  }
};

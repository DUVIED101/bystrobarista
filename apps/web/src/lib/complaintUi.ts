import type { ComplaintStatusGroup } from "@bystrobarista/core/types";

// Mobile parity: components/complaints/complaintUi.ts badge colors.
export const COMPLAINT_STATUS_BADGE: Record<ComplaintStatusGroup, string> = {
  open: "bg-[#F59E0B]",
  in_review: "bg-[#3B82F6]",
  resolved: "bg-[#10B981]",
  dismissed: "bg-[#6B7280]",
};

export const COMPLAINT_SEVERITY_BORDER: Record<string, string> = {
  warning: "border-[#F59E0B] text-[#F59E0B]",
  serious: "border-[#FF8C00] text-[#FF8C00]",
  critical: "border-[#EF4444] text-[#EF4444]",
};

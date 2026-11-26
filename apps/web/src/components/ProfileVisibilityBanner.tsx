"use client";

import Link from "next/link";
import React, { useState } from "react";
import { useTranslation } from "react-i18next";
import { useQueryClient } from "@tanstack/react-query";
import { getPlatform } from "@bystrobarista/core/platform";
import { BaristaProfileService } from "@bystrobarista/core/services/BaristaProfileService";
import type { BaristaProfile } from "@bystrobarista/core/types/baristaProfile";
import {
  formatMissingFields,
  getProfileVisibility,
} from "@bystrobarista/core/utils/profileVisibility";

const bannerClass =
  "mb-4 rounded-card border border-[#FCD34D] bg-[#FEF3C7] px-4 py-3 text-[#92400E]";

export function ProfileVisibilityBanner({
  profile,
}: {
  profile: BaristaProfile;
}): React.JSX.Element | null {
  const { t } = useTranslation();
  const queryClient = useQueryClient();
  const [isSaving, setIsSaving] = useState(false);

  const { visible, reasons, missing } = getProfileVisibility(profile);
  if (visible) return null;
  const shownMissing =
    profile.workExperiences === undefined
      ? missing.filter((field) => field !== "workHistory")
      : missing;
  const isNotLooking = reasons.includes("not_looking");
  const missingFields = formatMissingFields(shownMissing, (key) => t(key));

  const handleLookingToggle = async (value: boolean): Promise<void> => {
    setIsSaving(true);
    try {
      await BaristaProfileService.updateProfile(profile.userId, {
        isActivelyLooking: value,
      });
      await queryClient.invalidateQueries({ queryKey: ["baristaProfile"] });
    } catch (err) {
      console.error("Error in ProfileVisibilityBanner.toggle:", err);
      getPlatform().alert.show(
        t("common.error"),
        t("common.somethingWentWrong"),
      );
    } finally {
      setIsSaving(false);
    }
  };

  return (
    <>
      {isNotLooking && (
        <div role="status" className={bannerClass}>
          <p className="font-semibold">
            {t("profileVisibility.notLooking.title")}
          </p>
          <p className="mt-0.5 text-sm">
            {t("profileVisibility.notLooking.body")}
          </p>
          <label className="mt-2 flex min-h-[44px] cursor-pointer items-center justify-between gap-3 rounded-input bg-white/70 px-3 py-2">
            <span className="text-sm font-medium">
              {t("profileVisibility.notLooking.toggle")}
            </span>
            <input
              type="checkbox"
              checked={profile.isActivelyLooking}
              disabled={isSaving}
              onChange={(e) => void handleLookingToggle(e.target.checked)}
              className="h-5 w-5 accent-primary"
            />
          </label>
        </div>
      )}
      {!isNotLooking && reasons.includes("below_threshold") && (
        <div role="status" className={bannerClass}>
          <p className="font-semibold">
            {t("profileVisibility.belowThreshold.title")}
          </p>
          <p className="mt-0.5 text-sm">
            {missingFields
              ? t("profileVisibility.belowThreshold.body", {
                  fields: missingFields,
                })
              : t("profileVisibility.belowThreshold.bodyGeneric")}
          </p>
          <Link
            href="/profile/edit"
            className="mt-2 inline-block rounded-card bg-primary px-4 py-2 text-sm font-semibold text-white"
          >
            {t("profileVisibility.belowThreshold.cta")}
          </Link>
        </div>
      )}
    </>
  );
}

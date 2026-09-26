"use client";

import { useEffect } from "react";
import { UserService } from "@bystrobarista/core/services/UserService";
import { useAuthStore } from "@bystrobarista/core/stores/authStore";

// Headless: marks the signed-in user as seen when the app opens and whenever
// the tab becomes visible again; the server keeps at most one write per
// 5 minutes. Mounted once in the (app) layout.
export function LastSeenWatcher(): null {
  const userId = useAuthStore((s) => s.user?.id);

  useEffect(() => {
    if (!userId) return;
    void UserService.touchLastSeen();
    const onVisible = (): void => {
      if (document.visibilityState === "visible") {
        void UserService.touchLastSeen();
      }
    };
    document.addEventListener("visibilitychange", onVisible);
    return () => document.removeEventListener("visibilitychange", onVisible);
  }, [userId]);

  return null;
}

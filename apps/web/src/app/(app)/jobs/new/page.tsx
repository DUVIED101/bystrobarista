"use client";

import { useSearchParams } from "next/navigation";
import React, { Suspense } from "react";
import type { UserId } from "@bystrobarista/core/types/ids";
import { JobForm } from "@/components/JobForm";

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function CreateJobForm(): React.JSX.Element {
  const offerTo = useSearchParams().get("offerTo");
  return (
    <JobForm
      offerToBaristaId={
        offerTo && UUID_PATTERN.test(offerTo) ? (offerTo as UserId) : undefined
      }
    />
  );
}

export default function CreateJobPage(): React.JSX.Element {
  return (
    <Suspense fallback={null}>
      <CreateJobForm />
    </Suspense>
  );
}

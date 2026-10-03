import { Suspense } from "react";
import { PayFlow } from "@/components/PayFlow";

export default function PayPage() {
  return (
    <Suspense>
      <PayFlow />
    </Suspense>
  );
}

import { LoaderCircle } from "lucide-react";
import type { ComponentProps } from "react";

import { cn } from "@/utils/cn";

export function LoadingSpinner({
  className,
  ...props
}: ComponentProps<typeof LoaderCircle>) {
  return (
    <LoaderCircle
      aria-hidden="true"
      className={cn("animate-spin", className)}
      {...props}
    />
  );
}

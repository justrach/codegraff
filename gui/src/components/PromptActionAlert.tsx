import type { ReactNode } from "react";

import {
  Alert,
  AlertAction,
  AlertDescription,
  AlertTitle,
} from "@/components/ui/alert";
import { Button } from "@/components/ui/Button";

interface PromptActionAlertProps {
  actionLabel: string;
  children?: ReactNode;
  description?: ReactNode;
  onAction: () => void;
  title?: ReactNode;
}

export function PromptActionAlert({
  actionLabel,
  children,
  description,
  onAction,
  title,
}: PromptActionAlertProps) {
  return (
    <Alert className="mb-2">
      {title != null ? <AlertTitle>{title}</AlertTitle> : null}
      {description != null || children != null ? (
        <AlertDescription>{description ?? children}</AlertDescription>
      ) : null}
      <AlertAction className="">
        <Button type="button" size="sm" onClick={onAction}>
          {actionLabel}
        </Button>
      </AlertAction>
    </Alert>
  );
}

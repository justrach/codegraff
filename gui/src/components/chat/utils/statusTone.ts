import type { StatusCategory } from "@/services/desktop/types/contracts";

export function getStatusToneClass(category: StatusCategory): string {
  switch (category) {
    case "error":
      return "text-destructive";
    case "warning":
      return "text-warn";
    case "completion":
      return "text-success";
    default:
      return "text-muted-foreground";
  }
}

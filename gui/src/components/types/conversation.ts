import type { ChatBinding } from "@/services/desktop/types/contracts";

export interface ConversationPanelProps {
  binding?: ChatBinding | null;
  canCloseChat?: () => boolean;
  onCloseChat?: () => void;
  onOpenPreview?: () => void;
  onOpenTerminal?: () => void;
  reserveTitlebarInset?: boolean;
  showHeader?: boolean;
  windowDragEnabled?: boolean;
}

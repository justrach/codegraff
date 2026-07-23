import {
  PlusIcon,
  RotateCcwIcon,
  SquareTerminalIcon,
  XIcon,
} from "lucide-react";
import type {
  IDockviewHeaderActionsProps,
  IDockviewPanelHeaderProps,
  IDockviewPanelProps,
} from "dockview-react";

import { ConversationPanel } from "@/components/ConversationPanel";
import { ConversationDockviewHeaderActions } from "@/components/conversation-panel/ConversationDockviewHeaderActions";
import { Button } from "@/components/ui/Button";
import { ButtonGroup } from "@/components/ui/ButtonGroup";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/Dialog";

import { AuxiliaryPaneShell } from "./AuxiliaryPaneShell";
import { ChangesPane } from "./ChangesPane";
import { PlaceholderPane } from "./PlaceholderPane";
import { TerminalPane } from "./TerminalPane";
import {
  CHAT_PANE_ID,
  createTerminalSessionId,
  dispatchPaneCloseRequest,
  dispatchTerminalRestartRequest,
} from "./layout";
import type {
  PlaceholderPaneParams,
  TerminalPaneParams,
} from "./types/layout";
import type { ChatTileProps } from "./types/workspaceBoard";

const headerActionsClassName =
  "relative z-20 ml-auto flex h-6 shrink-0 items-center gap-1.5 pointer-events-auto";

export function AuxiliaryPaneTab({
  api,
  params,
}: IDockviewPanelHeaderProps<PlaceholderPaneParams>) {
  const isTerminal = params.kind === "terminal";

  return (
    <div className="terminal-pane-tab group/tab inline-flex h-6 min-w-0 items-center gap-1.5 px-1.5 text-xs font-medium tracking-tight text-foreground">
      {isTerminal ? (
        <SquareTerminalIcon className="size-3.5 shrink-0 text-muted-foreground" />
      ) : null}
      <span className="truncate">{params.label}</span>
      {isTerminal ? (
        <button
          type="button"
          aria-label={`Close ${params.label}`}
          className="ml-0.5 inline-flex size-4 shrink-0 items-center justify-center rounded text-muted-foreground opacity-0 transition-all hover:bg-muted hover:text-foreground focus-visible:opacity-100 group-hover/tab:opacity-100"
          onPointerDown={(event) => {
            event.stopPropagation();
          }}
          onClick={(event) => {
            event.stopPropagation();
            dispatchPaneCloseRequest(`${params.conversationId}:${api.id}`);
          }}
        >
          <XIcon className="size-3" />
        </button>
      ) : null}
    </div>
  );
}

interface ChatTileHeaderActionsProps extends IDockviewHeaderActionsProps {
  binding: ChatTileProps["binding"];
  canCloseChat: ChatTileProps["canCloseChat"];
  isChangesOpen: boolean;
  isTerminalOpen: boolean;
  onAddTerminal: () => void;
  onCloseChat: ChatTileProps["onCloseChat"];
  onOpenChanges: () => void;
  onOpenPane: (kind: "preview" | "terminal" | "changes") => void;
  onToggleTerminal: () => void;
}

export function ChatTileHeaderActions({
  activePanel,
  binding,
  canCloseChat,
  isChangesOpen,
  isTerminalOpen,
  onAddTerminal,
  onCloseChat,
  onOpenChanges,
  onOpenPane,
  onToggleTerminal,
}: ChatTileHeaderActionsProps) {
  if (activePanel?.id === CHAT_PANE_ID) {
    return (
      <ConversationDockviewHeaderActions
        binding={binding}
        canCloseChat={canCloseChat}
        onCloseChat={onCloseChat}
        onOpenPreview={() => onOpenPane("preview")}
        onOpenTerminal={onToggleTerminal}
        onOpenChanges={onOpenChanges}
        isChangesOpen={isChangesOpen}
        isTerminalOpen={isTerminalOpen}
      />
    );
  }

  const panelParams = activePanel?.params as
    | Partial<PlaceholderPaneParams>
    | undefined;
  const kind = panelParams?.kind;

  if (
    activePanel == null ||
    (kind !== "preview" && kind !== "terminal" && kind !== "changes")
  ) {
    return null;
  }

  const handleClose = () => {
    dispatchPaneCloseRequest(`${binding.conversationId}:${activePanel.id}`);
  };

  if (kind === "preview" || kind === "changes") {
    return (
      <div className={headerActionsClassName}>
        <Button
          variant="outline"
          size="icon-sm"
          aria-label={kind === "changes" ? "Close changes" : "Close preview"}
          onClick={handleClose}
        >
          <XIcon />
        </Button>
      </div>
    );
  }

  const resolvedParams = panelParams ?? {};
  const workspacePath =
    typeof resolvedParams.workspacePath === "string"
      ? resolvedParams.workspacePath
      : "";
  const conversationId =
    typeof resolvedParams.conversationId === "string"
      ? resolvedParams.conversationId
      : "";
  const terminalId = createTerminalSessionId(
    { workspacePath, conversationId },
    resolvedParams.terminalKey,
  );

  return (
    <div className={headerActionsClassName}>
      <Button
        variant="outline"
        size="icon-sm"
        aria-label="New terminal"
        onClick={onAddTerminal}
      >
        <PlusIcon />
      </Button>
      <ButtonGroup aria-label="Terminal actions">
        <Button
          variant="outline"
          size="icon-sm"
          aria-label="Restart terminal"
          onClick={() => dispatchTerminalRestartRequest(terminalId)}
        >
          <RotateCcwIcon />
        </Button>
        <Button
          variant="outline"
          size="icon-sm"
          aria-label="Close terminal"
          onClick={handleClose}
        >
          <XIcon />
        </Button>
      </ButtonGroup>
    </div>
  );
}

interface ChatTileConversationPaneProps extends ChatTileProps {
  onOpenPane: (kind: "preview" | "terminal" | "changes") => void;
}

export function ChatTileConversationPane({
  binding,
  canCloseChat,
  onCloseChat,
  onOpenPane,
}: ChatTileConversationPaneProps) {
  return (
    <ConversationPanel
      binding={binding}
      canCloseChat={canCloseChat}
      onCloseChat={onCloseChat}
      onOpenPreview={() => onOpenPane("preview")}
      onOpenTerminal={() => onOpenPane("terminal")}
      showHeader={false}
      windowDragEnabled={false}
    />
  );
}

export function ChatTileAuxiliaryPane(
  props: IDockviewPanelProps<PlaceholderPaneParams>,
) {
  const kind = props.params.kind;
  const content =
    kind === "terminal" ? (
      <TerminalPane
        {...(props as IDockviewPanelProps<TerminalPaneParams>)}
      />
    ) : kind === "changes" ? (
      <ChangesPane {...props} />
    ) : (
      <PlaceholderPane {...props} />
    );

  return (
    <AuxiliaryPaneShell
      api={props.api}
      paneId={`${props.params.conversationId}:${props.api.id}`}
    >
      {content}
    </AuxiliaryPaneShell>
  );
}

interface CloseTerminalsDialogProps {
  count: number;
  onCancel: () => void;
  onConfirm: () => void;
}

export function CloseTerminalsDialog({
  count,
  onCancel,
  onConfirm,
}: CloseTerminalsDialogProps) {
  return (
    <Dialog
      open={count > 0}
      onOpenChange={(open) => {
        if (!open) {
          onCancel();
        }
      }}
    >
      <DialogContent className="max-w-md">
        <DialogHeader>
          <DialogTitle>Close {count} terminals?</DialogTitle>
          <DialogDescription>
            This closes every terminal tab and ends its shell session. This
            can't be undone.
          </DialogDescription>
        </DialogHeader>
        <DialogFooter>
          <Button type="button" variant="outline" onClick={onCancel}>
            Cancel
          </Button>
          <Button type="button" variant="destructive" onClick={onConfirm}>
            Close terminals
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

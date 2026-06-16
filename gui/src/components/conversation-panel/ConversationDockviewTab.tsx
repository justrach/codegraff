import { ChevronRight, GitFork } from "lucide-react";

import { useSidebarVisible } from "@/app/sidebarVisibilityContext";
import {
  Breadcrumb,
  BreadcrumbItem,
  BreadcrumbList,
  BreadcrumbPage,
} from "@/components/ui/Breadcrumb";
import { cn } from "@/utils/cn";

import { BranchSwitcherMenu } from "./BranchSwitcherMenu";
import { useConversationHeaderState } from "./hooks/useConversationHeaderState";
import type { ConversationDockviewTabProps } from "./types/conversationHeader";

export function ConversationDockviewTab({
  binding,
}: ConversationDockviewTabProps) {
  const {
    activeWorkspaceLabel,
    branchName,
    branchQuery,
    branchSearchInputRef,
    canCreateBranch,
    conversationTitle,
    filteredBranches,
    isBranchMenuOpen,
    isGitActionPending,
    isManagedChat,
    repoName,
    setBranchQuery,
    handleBranchCreate,
    handleBranchMenuOpenChange,
    handleBranchSelect,
  } = useConversationHeaderState(binding);
  const isSidebarVisible = useSidebarVisible();
  // When the sidebar is collapsed the tile sits flush against the window's
  // left edge, so reserve room for the macOS traffic lights (mirrors
  // ConversationPanelHeader's reserveTitlebarInset).
  const reserveTitlebarInset = !isSidebarVisible;

  return (
    <div
      className={cn(
        "chat-pane-dockview-tab flex h-full min-w-0 items-center",
        reserveTitlebarInset ? "pl-34" : "pl-3",
      )}
    >
      <div className="relative z-20 flex min-w-0 shrink items-center overflow-hidden text-xs font-medium tracking-tight">
        {reserveTitlebarInset ? (
          <div className="mr-3 h-9 w-px shrink-0 bg-black/5 dark:bg-white/5" />
        ) : null}
        {isManagedChat ? (
          <span className="pointer-events-none truncate text-xs font-medium tracking-tight text-foreground">
            {conversationTitle}
          </span>
        ) : repoName ? (
          <Breadcrumb className="min-w-0">
            <BreadcrumbList className="min-w-0 flex-nowrap">
              <BreadcrumbItem className="min-w-0">
                <BreadcrumbPage className="pointer-events-none inline-flex min-w-0 items-center gap-1.5 text-xs font-medium text-foreground">
                  <GitFork
                    strokeWidth={2}
                    className="size-3 shrink-0 text-muted-foreground"
                  />
                  <span className="truncate">{repoName}</span>
                </BreadcrumbPage>
              </BreadcrumbItem>

              {branchName ? (
                <BreadcrumbItem className="min-w-0">
                  <div
                    className="ml-1.5 flex min-w-0 shrink items-center gap-0"
                    onPointerDownCapture={(event) => {
                      event.stopPropagation();
                    }}
                    onDragStartCapture={(event) => {
                      event.preventDefault();
                      event.stopPropagation();
                    }}
                  >
                    <ChevronRight
                      strokeWidth={2}
                      className="size-2.5 shrink-0 text-muted-foreground"
                    />
                    <BranchSwitcherMenu
                      branchName={branchName}
                      branchQuery={branchQuery}
                      branches={filteredBranches}
                      canCreateBranch={canCreateBranch}
                      isBusy={isGitActionPending}
                      isOpen={isBranchMenuOpen}
                      searchInputRef={branchSearchInputRef}
                      onBranchQueryChange={setBranchQuery}
                      onCreateBranch={handleBranchCreate}
                      onOpenChange={handleBranchMenuOpenChange}
                      onSelectBranch={handleBranchSelect}
                      triggerClassName="ml-0"
                    />
                  </div>
                </BreadcrumbItem>
              ) : null}
            </BreadcrumbList>
          </Breadcrumb>
        ) : (
          <span className="pointer-events-none truncate text-xs font-medium tracking-tight text-muted-foreground">
            {activeWorkspaceLabel}
          </span>
        )}
      </div>
    </div>
  );
}

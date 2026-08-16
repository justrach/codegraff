import { ChevronRight } from "lucide-react";

import {
  Breadcrumb,
  BreadcrumbItem,
  BreadcrumbList,
  BreadcrumbPage,
  BreadcrumbSeparator,
} from "@/components/ui/Breadcrumb";
import { cn } from "@/utils/cn";
import { handleWindowDragStart } from "@/utils/window";

import { BranchSwitcherMenu } from "./BranchSwitcherMenu";
import { ChatHandoffDialog } from "./ChatHandoffDialog";
import { ConversationHeaderActions } from "./ConversationHeaderActions";
import { ProjectSwitcherMenu } from "./ProjectSwitcherMenu";
import { useConversationHeaderState } from "./hooks/useConversationHeaderState";
import type { ConversationPanelHeaderProps } from "./types/conversationHeader";

export function ConversationPanelHeader({
  binding,
  canCloseChat,
  onCloseChat,
  onOpenPreview,
  onOpenTerminal,
  reserveTitlebarInset,
  windowDragEnabled,
}: ConversationPanelHeaderProps) {
  const {
    branchName,
    branchQuery,
    branchSearchInputRef,
    canCreateBranch,
    conversationTitle,
    currentProjectLabel,
    filteredBranches,
    handoffBranchName,
    handoffTarget,
    isBranchMenuOpen,
    isGitActionPending,
    isHandoffDialogOpen,
    isHandoffPending,
    isManagedChat,
    isOpenTargetPending,
    isProjectChangePending,
    canHandoffToLocal,
    canHandoffToWorktree,
    openTargets,
    projects,
    resolvedPreferredAppId,
    selectedProjectPath,
    setBranchQuery,
    setHandoffBranchName,
    handleBranchCreate,
    handleBranchMenuOpenChange,
    handleBranchSelect,
    handleHandoffDialogClose,
    handleHandoffDialogOpenChange,
    handleHandoffSubmit,
    handleStartHandoff,
    handleOpenTarget,
    handleProjectSelect,
  } = useConversationHeaderState(binding);
  const windowDragClassName = cn("bg-transparent");

  return (
    <>
      <header
        className={cn(
          "flex h-9.5 items-center gap-3 border-b border-border pr-19 select-none",
          reserveTitlebarInset ? "pl-34" : "pl-3",
        )}
      >
        <div className="relative z-20 flex min-w-0 shrink items-center overflow-hidden text-xs font-medium tracking-tight">
          {reserveTitlebarInset ? (
            <div className="mr-3 h-9 w-px shrink-0 bg-black/5 dark:bg-white/5" />
          ) : null}
          <Breadcrumb className="min-w-0">
            <BreadcrumbList className="min-w-0 flex-nowrap">
              <BreadcrumbItem className="min-w-0">
                <ProjectSwitcherMenu
                  currentProjectLabel={currentProjectLabel}
                  isBusy={isProjectChangePending}
                  projects={projects}
                  selectedProjectPath={selectedProjectPath}
                  onSelectProject={handleProjectSelect}
                />
              </BreadcrumbItem>

              {isManagedChat ? (
                <>
                  <BreadcrumbSeparator className="text-muted-foreground">
                    <ChevronRight strokeWidth={2} className="size-2.5" />
                  </BreadcrumbSeparator>
                  <BreadcrumbItem className="min-w-0">
                    <BreadcrumbPage className="pointer-events-none inline-flex min-w-0 items-center text-xs font-medium text-muted-foreground">
                      <span className="truncate">{conversationTitle}</span>
                    </BreadcrumbPage>
                  </BreadcrumbItem>
                </>
              ) : branchName ? (
                <>
                  <BreadcrumbSeparator className="text-muted-foreground">
                    <ChevronRight strokeWidth={2} className="size-2.5" />
                  </BreadcrumbSeparator>
                  <BreadcrumbItem className="min-w-0">
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
                    />
                  </BreadcrumbItem>
                </>
              ) : null}
            </BreadcrumbList>
          </Breadcrumb>
        </div>

        <div
          role="presentation"
          className={cn("h-full min-w-8 flex-1", windowDragClassName)}
          onMouseDown={windowDragEnabled ? handleWindowDragStart : undefined}
        />

        <ConversationHeaderActions
          canCloseChat={canCloseChat}
          canHandoffToLocal={canHandoffToLocal}
          canHandoffToWorktree={canHandoffToWorktree}
          isHandoffBusy={isHandoffPending}
          isOpenTargetBusy={isOpenTargetPending}
          onCloseChat={onCloseChat}
          onHandoffToLocal={() => {
            void handleStartHandoff("local");
          }}
          onHandoffToWorktree={() => {
            void handleStartHandoff("worktree");
          }}
          onOpenPreview={onOpenPreview}
          onOpenTerminal={onOpenTerminal}
          onSelectOpenTarget={handleOpenTarget}
          openTargets={openTargets}
          preferredAppId={resolvedPreferredAppId}
        />
      </header>

      <ChatHandoffDialog
        branchName={handoffBranchName}
        isOpen={isHandoffDialogOpen}
        isSubmitting={isHandoffPending}
        onBranchNameChange={setHandoffBranchName}
        onClose={handleHandoffDialogClose}
        onOpenChange={handleHandoffDialogOpenChange}
        onSubmit={handleHandoffSubmit}
        target={handoffTarget}
      />
    </>
  );
}

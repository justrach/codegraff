import { useMemo, useState } from "react";

import {
  FolderPlus,
  PanelsTopLeft,
  PenSquare,
  Plug2Icon,
  ServerIcon,
  Settings2Icon,
  Trash2Icon,
} from "lucide-react";

import { BrandMark } from "./BrandMark";
import { isNativeBridgeAvailable, openExternalUrl } from "../services/desktop/client";
import { useExpandedProjectPaths } from "../hooks/useExpandedProjectPaths";
import {
  useSessionActions,
  useSidebarSession,
} from "../hooks/useSession";
import { formatRelativeTimestamp } from "../utils/time";
import { handleWindowDragStart } from "../utils/window";
import { ProjectSidebarActions } from "./ProjectSidebarActions";
import { SidebarArchiveAction } from "./SidebarArchiveAction";
import { SidebarItemActionsMenu } from "./SidebarItemActionsMenu";
import { SidebarSettingsControl } from "./SidebarSettingsControl";
import { ProjectSidebarProject } from "./ProjectSidebarProject";
import type { ProjectSidebarProps } from "./types/sidebar";
import { Button } from "./ui/Button";
import {
  Sidebar,
  SidebarContent,
  SidebarGroup,
  SidebarGroupContent,
  SidebarGroupLabel,
  SidebarHeader,
  SidebarMenu,
  SidebarMenuButton,
  SidebarMenuItem,
} from "./ui/Sidebar";

const CODEGRAFF_GITHUB_URL = "https://github.com/justrach/codegraff";

function SidebarWatermark() {
  function handleOpenGithub() {
    void openExternalUrl(CODEGRAFF_GITHUB_URL).catch((error) => {
      console.error("Failed to open Codegraff GitHub link", error);
    });
  }

  return (
    <button
      type="button"
      className="pointer-events-auto flex cursor-pointer items-center justify-start gap-2 rounded-lg px-2 py-1 text-sm font-medium tracking-tight text-sidebar-foreground/55 transition-colors hover:bg-sidebar-accent/60 hover:text-sidebar-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-sidebar-ring"
      aria-label="Open Codegraff on GitHub"
      title="Open Codegraff on GitHub"
      onClick={handleOpenGithub}
    >
      <BrandMark className="size-8" />
      <span>codegraff</span>
    </button>
  );
}

export function ProjectSidebar({
  isSettingsViewOpen,
  selectedSettingsSection,
  onOpenSettings,
  onSelectSettingsSection,
}: ProjectSidebarProps) {
  const {
    collapseProject,
    ensureProjectExpanded,
    isProjectExpanded,
    toggleProjectExpanded,
  } = useExpandedProjectPaths();
  const {
    archiveConversation,
    archiveWorkspace,
    deleteSavedWorkspace,
    openWorkspacePicker,
    openProject,
    openSavedWorkspace,
    renameSavedWorkspace,
    renameWorkspace,
    selectConversation,
    startNewChat,
  } = useSessionActions();
  const {
    activeConversationId,
    activeSavedWorkspaceId,
    activeWorkspacePath,
    savedWorkspaces,
    workspaces,
  } = useSidebarSession();
  const [actionNotice, setActionNotice] = useState<string | null>(null);
  const projectWorkspaces = useMemo(
    () => workspaces.filter((workspace) => workspace.kind === "project"),
    [workspaces],
  );
  const visibleManagedChats = useMemo(
    () =>
      workspaces.filter(
        (workspace) =>
          workspace.kind === "managed_chat" &&
          workspace.conversations.some((conversation) => !conversation.isDraft),
      ),
    [workspaces],
  );

  async function handleOpenWorkspacePicker() {
    setActionNotice(null);
    if (!isNativeBridgeAvailable()) {
      setActionNotice("Open project requires the desktop app in this preview.");
      return;
    }
    const selectedPath = await openWorkspacePicker();
    if (selectedPath == null) {
      return;
    }

    ensureProjectExpanded(selectedPath);
  }

  function handleSelectConversation(
    workspacePath: string,
    conversationId: string,
  ) {
    void selectConversation(workspacePath, conversationId);
  }

  function handleArchiveConversation(
    workspacePath: string,
    conversationId: string,
  ) {
    void archiveConversation(workspacePath, conversationId);
  }

  function handleArchiveWorkspace(workspacePath: string) {
    collapseProject(workspacePath);
    void archiveWorkspace(workspacePath);
  }

  async function handleRenameProject(
    workspacePath: string,
    displayName?: string | null,
  ) {
    await renameWorkspace(workspacePath, displayName ?? null);
  }

  function handleDeleteSavedWorkspace(workspaceId: string) {
    void deleteSavedWorkspace(workspaceId);
  }

  async function handleRenameSavedWorkspace(workspaceId: string, name: string) {
    await renameSavedWorkspace(workspaceId, name);
  }

  function handleStartNewChat(workspacePath?: string) {
    void startNewChat(workspacePath);
  }

  if (isSettingsViewOpen) {
    return (
      <Sidebar
        collapsible="none"
        className="relative w-full border-r-0 bg-sidebar"
      >
        <SidebarHeader className="relative pb-1 pt-10">
          <div
            className="absolute inset-x-0 top-0 h-9 bg-transparent"
            role="presentation"
            onMouseDown={handleWindowDragStart}
          />
        </SidebarHeader>

        <SidebarContent className="select-none pb-16">
          <SidebarGroup className="pt-0">
            <div className="mb-1 flex h-7 items-center justify-between px-2">
              <SidebarGroupLabel className="h-full px-0 font-medium">
                Settings
              </SidebarGroupLabel>
            </div>

            <SidebarGroupContent>
              <SidebarMenu>
                <SidebarMenuItem>
                  <SidebarMenuButton
                    isActive={selectedSettingsSection === "general"}
                    tooltip="General"
                    className="font-medium [&_svg]:size-3.5"
                    onClick={() => {
                      onSelectSettingsSection("general");
                    }}
                  >
                    <Settings2Icon
                      strokeWidth={2}
                      className="size-3.5 shrink-0"
                    />
                    <span>General</span>
                  </SidebarMenuButton>
                </SidebarMenuItem>
                <SidebarMenuItem>
                  <SidebarMenuButton
                    isActive={selectedSettingsSection === "providers"}
                    tooltip="Providers"
                    className="font-medium [&_svg]:size-3.5"
                    onClick={() => {
                      onSelectSettingsSection("providers");
                    }}
                  >
                    <Plug2Icon strokeWidth={2} className="size-3.5 shrink-0" />
                    <span>Providers</span>
                  </SidebarMenuButton>
                </SidebarMenuItem>
                <SidebarMenuItem>
                  <SidebarMenuButton
                    isActive={selectedSettingsSection === "mcp"}
                    tooltip="MCP"
                    className="font-medium [&_svg]:size-3.5"
                    onClick={() => {
                      onSelectSettingsSection("mcp");
                    }}
                  >
                    <ServerIcon strokeWidth={2} className="size-3.5 shrink-0" />
                    <span>MCP</span>
                  </SidebarMenuButton>
                </SidebarMenuItem>
              </SidebarMenu>
            </SidebarGroupContent>
          </SidebarGroup>
        </SidebarContent>

        <div className="pb-3">
          <SidebarWatermark />
        </div>
      </Sidebar>
    );
  }

  return (
    <Sidebar
      collapsible="none"
      className="relative w-full border-r-0 bg-sidebar"
    >
      <SidebarHeader className="relative pb-1 pt-10">
        <div
          className="absolute inset-x-0 top-0 h-9 bg-transparent"
          role="presentation"
          onMouseDown={handleWindowDragStart}
        />
        <ProjectSidebarActions
          onOpenWorkspacePicker={() => void handleOpenWorkspacePicker()}
        />
        {actionNotice != null ? (
          <div className="mx-2 rounded-xl border border-warn/25 bg-warn/10 px-3 py-2 text-xs/relaxed text-sidebar-foreground">
            {actionNotice}
          </div>
        ) : null}
      </SidebarHeader>

      <SidebarContent className="select-none pb-24">
        <SidebarGroup className="pt-0">
          <div className="mb-1 flex h-7 items-center justify-between px-2">
            <SidebarGroupLabel className="h-full px-0 font-medium">
              Workspaces
            </SidebarGroupLabel>
          </div>

          <SidebarGroupContent>
            {savedWorkspaces.length === 0 ? (
              <p className="px-2 py-1 text-xs font-medium text-sidebar-foreground/60">
                No workspaces yet
              </p>
            ) : (
              <SidebarMenu>
                {savedWorkspaces.map((workspace) => (
                  <SidebarMenuItem key={workspace.id}>
                    <SidebarMenuButton
                      isActive={workspace.id === activeSavedWorkspaceId}
                      tooltip={workspace.name}
                      className="pr-8 font-medium"
                      onClick={() => {
                        void openSavedWorkspace(workspace.id);
                      }}
                    >
                      <PanelsTopLeft strokeWidth={2} className="size-3.5" />
                      <span>{workspace.name}</span>
                    </SidebarMenuButton>
                    <SidebarItemActionsMenu
                      className="right-0"
                      currentName={workspace.name}
                      dialogDescription="Update the saved workspace name shown in the sidebar."
                      dialogTitle="Rename workspace"
                      menuAriaLabel={`More actions for ${workspace.name}`}
                      onRemove={() => handleDeleteSavedWorkspace(workspace.id)}
                      onRename={(name) =>
                        handleRenameSavedWorkspace(
                          workspace.id,
                          name ?? workspace.name,
                        )
                      }
                      removeIcon={Trash2Icon}
                    />
                  </SidebarMenuItem>
                ))}
              </SidebarMenu>
            )}
          </SidebarGroupContent>
        </SidebarGroup>

        <SidebarGroup className="pt-0">
          <div className="mb-1 flex h-7 items-center justify-between px-2">
            <SidebarGroupLabel className="h-full px-0 font-medium">
              Chats
            </SidebarGroupLabel>
          </div>

          <SidebarGroupContent>
            {visibleManagedChats.length === 0 ? (
              <p className="px-2 py-1 text-xs font-medium text-sidebar-foreground/60">
                No chats yet
              </p>
            ) : (
              <SidebarMenu>
                {visibleManagedChats.map((chatWorkspace) => {
                  const isChatOpen =
                    chatWorkspace.workspacePath === activeWorkspacePath;
                  const visibleConversation =
                    chatWorkspace.conversations.find(
                      (conversation) => !conversation.isDraft,
                    ) ?? null;
                  if (visibleConversation == null) {
                    return null;
                  }
                  const activeChatId =
                    chatWorkspace.selectedConversationId ??
                    visibleConversation.conversationId;
                  const isActive =
                    isChatOpen && activeConversationId === activeChatId;
                  const chatTitle = visibleConversation.title;
                  const updatedAt = formatRelativeTimestamp(
                    visibleConversation.updatedAt ?? null,
                  );

                  return (
                    <SidebarMenuItem key={chatWorkspace.workspacePath}>
                      <SidebarMenuButton
                        isActive={isActive}
                        tooltip={chatTitle}
                        className="font-medium"
                        onClick={() => {
                          if (activeChatId != null) {
                            void selectConversation(
                              chatWorkspace.workspacePath,
                              activeChatId,
                            );
                            return;
                          }

                          void openProject(chatWorkspace.workspacePath);
                        }}
                      >
                        <PenSquare
                          strokeWidth={2}
                          className="size-3.5 shrink-0"
                        />
                        <span className="min-w-0 flex-1 truncate pr-2">
                          {chatTitle}
                        </span>
                        {updatedAt ? (
                          <span className="flex shrink-0 items-center gap-1.5 text-right text-xs font-medium text-sidebar-foreground/60 transition-opacity group-hover/menu-item:opacity-0 group-focus-within/menu-item:opacity-0">
                            {updatedAt}
                          </span>
                        ) : null}
                      </SidebarMenuButton>
                      <SidebarArchiveAction
                        ariaLabel={`Archive ${chatTitle}`}
                        className="right-0.5 group-hover/menu-item:opacity-100"
                        onClick={() =>
                          handleArchiveWorkspace(chatWorkspace.workspacePath)
                        }
                      />
                    </SidebarMenuItem>
                  );
                })}
              </SidebarMenu>
            )}
          </SidebarGroupContent>
        </SidebarGroup>

        <SidebarGroup className="pt-0">
          <div className="mb-1 flex h-7 items-center justify-between px-2">
            <SidebarGroupLabel className="h-full px-0 font-medium">
              Projects
            </SidebarGroupLabel>
            <Button
              type="button"
              variant="ghost"
              size="icon"
              className="-mr-2"
              aria-label="Open project"
              title="Open project"
              onClick={() => void handleOpenWorkspacePicker()}
            >
              <FolderPlus strokeWidth={2} className="size-3.5 shrink-0" />
            </Button>
          </div>

          <SidebarGroupContent>
            {projectWorkspaces.length === 0 ? (
              <p className="px-2 py-1 text-xs font-medium text-sidebar-foreground/60">
                No projects yet
              </p>
            ) : (
              <SidebarMenu>
                {projectWorkspaces.map((project) => {
                  const isProjectOpen =
                    project.workspacePath === activeWorkspacePath;
                  const isActive =
                    isProjectOpen && activeConversationId == null;
                  const isExpanded = isProjectExpanded(project.workspacePath);
                  const selectedConversationId = isProjectOpen
                    ? (activeConversationId ?? project.selectedConversationId)
                    : null;

                  return (
                    <ProjectSidebarProject
                      key={project.workspacePath}
                      isExpanded={isExpanded}
                      isActive={isActive}
                      project={project}
                      selectedConversationId={selectedConversationId}
                      onArchiveConversation={handleArchiveConversation}
                      onArchiveProject={handleArchiveWorkspace}
                      onRenameProject={handleRenameProject}
                      onSelectConversation={handleSelectConversation}
                      onStartNewChat={handleStartNewChat}
                      onToggleProjectExpanded={toggleProjectExpanded}
                    />
                  );
                })}
              </SidebarMenu>
            )}
          </SidebarGroupContent>
        </SidebarGroup>

      </SidebarContent>

      <div className="pointer-events-none absolute inset-x-0 bottom-0 z-10 px-3 pb-3">
        <div className="absolute inset-x-0 bottom-0 h-28 bg-gradient-to-t from-sidebar via-sidebar/95 to-transparent" />
        <div className="relative flex flex-col gap-2">
          <SidebarWatermark />
          <div className="pointer-events-auto">
            <SidebarSettingsControl onOpenSettings={onOpenSettings} />
          </div>
        </div>
      </div>
    </Sidebar>
  );
}

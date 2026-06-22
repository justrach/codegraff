import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
} from "react";
import type { PanelImperativeHandle } from "react-resizable-panels";
import {
  ArrowLeftIcon,
  LoaderCircle,
  MoonIcon,
  PanelLeftIcon,
  PenSquare,
  SunIcon,
} from "lucide-react";

import { NewChatTrigger } from "../components/NewChatTrigger";
import { GeneralSettingsPane } from "../components/general-settings/GeneralSettingsPane";
import { McpSettingsPane } from "../components/mcp-settings/McpSettingsPane";
import { ProvidersSettingsPane } from "../components/providers-settings/ProvidersSettingsPane";
import { ProviderSuccessPage } from "../components/providers-settings/ProviderSuccessPage";
import { ProjectSidebar } from "../components/ProjectSidebar";
import { WorkspaceBoard } from "../components/workspace-board/WorkspaceBoard";
import { Button } from "../components/ui/Button";
import {
  ResizableHandle,
  ResizablePanel,
  ResizablePanelGroup,
} from "../components/ui/Resizable";
import { SidebarProvider, useSidebar } from "../components/ui/Sidebar";
import { TooltipProvider } from "../components/ui/Tooltip";
import { hydrateThemeSettings, useThemeStore } from "./themeStore";
import { SidebarVisibilityContext } from "./sidebarVisibilityContext";
import { useSessionStore } from "../hooks/useSession";
import { DragDropProvider } from "../hooks/useFileDrop";
import { SessionProvider } from "./SessionProvider";
import { SettingsNavigationProvider } from "./settingsNavigation";
import { setWindowTitle } from "../services/desktop/client";
import {
  getUiActiveWorkspacePath,
  getUiWorkspaceLabel,
  getWorkspaceMetaStoreKey,
} from "./sessionStore";
import {
  DEFAULT_SIDEBAR_WIDTH,
  MAX_SIDEBAR_WIDTH,
  MIN_SIDEBAR_WIDTH,
} from "./constants/layout";
import type {
  AppSidebarControlProps,
  SettingsSection,
} from "./types/app";

function AppThemeToggle({
  isDarkTheme,
  onToggleTheme,
}: {
  isDarkTheme: boolean;
  onToggleTheme: () => void;
}) {
  const label = isDarkTheme ? "Switch to light mode" : "Switch to dark mode";

  return (
    <Button
      variant="ghost"
      size="icon-sm"
      aria-label={label}
      title={label}
      className="absolute right-3 top-2 z-20"
      onClick={onToggleTheme}
    >
      {isDarkTheme ? (
        <SunIcon strokeWidth={2} className="size-3.5" />
      ) : (
        <MoonIcon strokeWidth={2} className="size-3.5" />
      )}
      <span className="sr-only">{label}</span>
    </Button>
  );
}

function AppSidebarControl({
  isFullscreen,
  isSidebarVisible,
  isSettingsViewOpen,
  onExitSettings,
  onToggleDesktopSidebar,
}: AppSidebarControlProps) {
  const { toggleSidebar } = useSidebar();
  const controlPositionClass = isFullscreen ? "left-3" : "left-20";

  if (isSettingsViewOpen) {
    return (
      <Button
        variant="ghost"
        size="icon-sm"
        aria-label="Back"
        className={`absolute top-2 z-20 ${controlPositionClass}`}
        onClick={onExitSettings}
      >
        <ArrowLeftIcon strokeWidth={2} className="size-3.5" />
        <span className="sr-only">Back</span>
      </Button>
    );
  }

  return (
    <Button
      variant="ghost"
      size="icon-sm"
      aria-label={isSidebarVisible ? "Hide sidebar" : "Show sidebar"}
      className={`absolute top-2 z-20 ${controlPositionClass}`}
      onClick={() => {
        toggleSidebar();
        onToggleDesktopSidebar();
      }}
    >
      <PanelLeftIcon strokeWidth={2} className="size-3.5" />
      <span className="sr-only">
        {isSidebarVisible ? "Hide sidebar" : "Show sidebar"}
      </span>
    </Button>
  );
}

function AppShell() {
  const isDarkTheme = useThemeStore((state) => state.mode === "dark");
  const toggleTheme = useThemeStore((state) => state.toggleMode);
  const isSessionBootstrapped = useSessionStore(
    (state) => state.isBootstrapped,
  );
  const windowTitle = useSessionStore((state) => {
    const workspacePath = getUiActiveWorkspacePath(state);
    if (workspacePath == null) {
      return "Codegraff";
    }
    const runtimeStatus =
      state.workspaceMetaByKey[getWorkspaceMetaStoreKey(workspacePath)]
        ?.runtimeStatus ?? null;
    return `${getUiWorkspaceLabel(workspacePath, runtimeStatus)} - Codegraff`;
  });
  const isFullscreen = false;
  const [isDesktopSidebarVisible, setIsDesktopSidebarVisible] = useState(true);
  const [isSettingsViewOpen, setIsSettingsViewOpen] = useState(false);
  const [selectedSettingsSection, setSelectedSettingsSection] =
    useState<SettingsSection>("general");
  const sidebarPanelRef = useRef<PanelImperativeHandle | null>(null);
  const [isSidebarAnimating, setIsSidebarAnimating] = useState(false);
  const sidebarAnimateTimeoutRef = useRef<number | null>(null);
  // Holds the latest openNewChat from the always-mounted NewChatTrigger so the
  // global Cmd/Ctrl+N shortcut can invoke it (including its git-worktree choice
  // dialog) no matter what's visible.
  const newChatRef = useRef<(() => void) | null>(null);
  // Briefly enable a width transition on the panels so toggling the sidebar
  // slides smoothly (like the artifacts drawer) instead of snapping. Kept off
  // during drag-resize so dragging stays 1:1 with the cursor.
  const runSidebarToggleAnimation = useCallback(() => {
    setIsSidebarAnimating(true);
    if (sidebarAnimateTimeoutRef.current != null) {
      window.clearTimeout(sidebarAnimateTimeoutRef.current);
    }
    sidebarAnimateTimeoutRef.current = window.setTimeout(() => {
      setIsSidebarAnimating(false);
      sidebarAnimateTimeoutRef.current = null;
    }, 340);
  }, []);
  const openProvidersSettings = useCallback(() => {
    setIsDesktopSidebarVisible(true);
    setSelectedSettingsSection("providers");
    setIsSettingsViewOpen(true);
  }, []);
  const openMcpSettings = useCallback(() => {
    setIsDesktopSidebarVisible(true);
    setSelectedSettingsSection("mcp");
    setIsSettingsViewOpen(true);
  }, []);

  useEffect(() => {
    void hydrateThemeSettings();
  }, []);

  useEffect(() => {
    void setWindowTitle(windowTitle).catch(() => undefined);
  }, [windowTitle]);
  const settingsNavigation = useMemo(
    () => ({
      openProviderSettings: openProvidersSettings,
      openMcpSettings,
    }),
    [openMcpSettings, openProvidersSettings],
  );

  useLayoutEffect(() => {
    const panel = sidebarPanelRef.current;
    if (panel == null) {
      return;
    }

    if (isDesktopSidebarVisible) {
      panel.expand();
      return;
    }

    panel.collapse();
  }, [isDesktopSidebarVisible]);

  useEffect(() => {
    return () => {
      if (sidebarAnimateTimeoutRef.current != null) {
        window.clearTimeout(sidebarAnimateTimeoutRef.current);
      }
    };
  }, []);

  // Global Cmd/Ctrl+N → new chat. Reuses NewChatTrigger's openNewChat (captured
  // in newChatRef) so the git-worktree choice dialog flows through identically.
  // Skipped while a settings view or dialog is open or while the session is
  // mid-bootstrap, and ignores key presses originating inside an input/textarea
  // so it never fights typing — though Cmd+N is uncommon enough to be safe.
  useEffect(() => {
    function handleKeyDown(event: KeyboardEvent) {
      if (!(event.metaKey || event.ctrlKey) || event.key !== "n") {
        return;
      }
      event.preventDefault();
      newChatRef.current?.();
    }

    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  }, []);

  if (!isSessionBootstrapped) {
    return (
      <main className="app-shell relative flex h-screen w-full items-center justify-center overflow-hidden bg-background">
        <LoaderCircle
          aria-hidden="true"
          className="size-5 animate-spin text-muted-foreground/70"
          strokeWidth={2}
        />
      </main>
    );
  }

  return (
    <TooltipProvider>
      <SidebarProvider className="min-h-screen bg-background">
        <main className="app-shell relative flex h-screen w-full overflow-hidden bg-background">
          <AppThemeToggle
            isDarkTheme={isDarkTheme}
            onToggleTheme={toggleTheme}
          />
          <AppSidebarControl
            isFullscreen={isFullscreen}
            isSidebarVisible={isDesktopSidebarVisible}
            isSettingsViewOpen={isSettingsViewOpen}
            onExitSettings={() => {
              setIsSettingsViewOpen(false);
            }}
            onToggleDesktopSidebar={() => {
              runSidebarToggleAnimation();
              setIsDesktopSidebarVisible((current) => {
                const nextIsVisible = !current;
                if (!nextIsVisible) {
                  setIsSettingsViewOpen(false);
                }
                return nextIsVisible;
              });
            }}
          />
          <NewChatTrigger>
            {({ isBusy, openNewChat }) => {
              newChatRef.current = openNewChat;
              if (isDesktopSidebarVisible || isSettingsViewOpen) {
                return null;
              }
              return (
                <Button
                  variant="ghost"
                  size="icon-sm"
                  aria-label="New chat"
                  className={`absolute top-2 z-20 ${isFullscreen ? "left-11" : "left-28"}`}
                  disabled={isBusy}
                  onClick={openNewChat}
                >
                  <PenSquare strokeWidth={2} className="size-3.5" />
                  <span className="sr-only">New chat</span>
                </Button>
              );
            }}
          </NewChatTrigger>
          <ResizablePanelGroup orientation="horizontal">
            <ResizablePanel
              id="sidebar-panel"
              panelRef={sidebarPanelRef}
              defaultSize={DEFAULT_SIDEBAR_WIDTH}
              minSize={MIN_SIDEBAR_WIDTH}
              maxSize={MAX_SIDEBAR_WIDTH}
              collapsible
              collapsedSize={0}
              groupResizeBehavior="preserve-pixel-size"
              className={`overflow-hidden${isSidebarAnimating ? " transition-[flex-grow] duration-300 ease-[cubic-bezier(0.16,1,0.3,1)]" : ""}`}
              onResize={(size) => {
                const nextIsVisible = size.inPixels > 0;
                if (!nextIsVisible) {
                  setIsSettingsViewOpen(false);
                }
                setIsDesktopSidebarVisible((current) =>
                  current === nextIsVisible ? current : nextIsVisible,
                );
              }}
            >
              <ProjectSidebar
                isSettingsViewOpen={isSettingsViewOpen}
                selectedSettingsSection={selectedSettingsSection}
                onOpenSettings={() => {
                  setIsDesktopSidebarVisible(true);
                  setIsSettingsViewOpen(true);
                }}
                onSelectSettingsSection={setSelectedSettingsSection}
              />
            </ResizablePanel>
            <ResizableHandle
              className={
                isDesktopSidebarVisible && !isSettingsViewOpen
                  ? "bg-transparent after:w-2 hover:after:bg-border/80"
                  : "w-0 bg-transparent after:hidden pointer-events-none"
              }
            />
            <ResizablePanel
              id="chat-panel"
              className={
                isSidebarAnimating
                  ? "transition-[flex-grow] duration-300 ease-[cubic-bezier(0.16,1,0.3,1)]"
                  : undefined
              }
            >
              <section className="flex h-full min-w-0 flex-1 overflow-hidden">
                {isSettingsViewOpen ? (
                  selectedSettingsSection === "providers" ? (
                    <ProvidersSettingsPane />
                  ) : selectedSettingsSection === "mcp" ? (
                    <McpSettingsPane />
                  ) : (
                    <GeneralSettingsPane />
                  )
                ) : (
                  <SettingsNavigationProvider value={settingsNavigation}>
                    <SidebarVisibilityContext.Provider
                      value={isDesktopSidebarVisible}
                    >
                      <WorkspaceBoard />
                    </SidebarVisibilityContext.Provider>
                  </SettingsNavigationProvider>
                )}
              </section>
            </ResizablePanel>
          </ResizablePanelGroup>
        </main>
      </SidebarProvider>
    </TooltipProvider>
  );
}

function App() {
  if (window.location.pathname === "/success") {
    return <ProviderSuccessPage />;
  }

  return (
    <SessionProvider>
      <DragDropProvider>
        <AppShell />
      </DragDropProvider>
    </SessionProvider>
  );
}

export default App;

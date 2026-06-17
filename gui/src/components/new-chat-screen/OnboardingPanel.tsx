import {
  CheckCircle2,
  Circle,
  FolderOpen,
  GitBranchPlus,
  KeyRound,
  MessageSquareText,
  Rocket,
  XIcon,
} from "lucide-react";
import type { ComponentType, ReactNode } from "react";

import { Button } from "@/components/ui/Button";
import { Card, CardContent } from "@/components/ui/Card";
import type {
  ProviderAuthMethodKind,
  ProviderSummary,
} from "@/services/desktop/types/contracts";
import { cn } from "@/utils/cn";

import { findApiKeyProvider } from "./utils/onboarding";

interface OnboardingPanelProps {
  hasProvider: boolean;
  hasWorkspace: boolean;
  isBusy: boolean;
  isLoadingProviders: boolean;
  onCollapse: () => void;
  onFocusPrompt: () => void;
  onOpenClone: () => void;
  onOpenFolder: () => void;
  onOpenProviderSetup: (
    providerIdOrProvider: string | ProviderSummary,
    authMethod?: ProviderAuthMethodKind,
  ) => boolean;
  onOpenQuickStart: () => void;
  onOpenSettings: () => void;
  providers: ProviderSummary[];
}

export function OnboardingPanel({
  hasProvider,
  hasWorkspace,
  isBusy,
  isLoadingProviders,
  onCollapse,
  onFocusPrompt,
  onOpenClone,
  onOpenFolder,
  onOpenProviderSetup,
  onOpenQuickStart,
  onOpenSettings,
  providers,
}: OnboardingPanelProps) {
  const isComplete = hasProvider && hasWorkspace;
  const apiKeyProvider = findApiKeyProvider(providers);

  return (
    <Card className="w-full border border-border/80 bg-card/95 shadow-sm">
      <CardContent className="flex flex-col gap-4 px-4">
        <div className="flex items-start justify-between gap-3">
          <div className="min-w-0">
            <div className="text-sm font-medium text-foreground">
              Set up the fastest path
            </div>
            <p className="mt-1 max-w-2xl text-xs/relaxed text-muted-foreground">
              Start with a free Codegraff login. Codex login is also picked up,
              and API keys can be added manually.
            </p>
          </div>
          {isComplete ? (
            <Button
              type="button"
              variant="ghost"
              size="icon-sm"
              aria-label="Collapse onboarding"
              onClick={onCollapse}
            >
              <XIcon className="size-3.5" />
            </Button>
          ) : (
            <Button
              type="button"
              variant="ghost"
              size="sm"
              onClick={onOpenSettings}
            >
              Settings
            </Button>
          )}
        </div>

        <div className="grid gap-3">
          <ChecklistItem
            complete={hasProvider}
            description={
              hasProvider
                ? "Provider credentials are ready."
                : "Use Codegraff first, or connect Codex/API-key providers."
            }
            icon={KeyRound}
            title="Connect provider"
          >
            {!hasProvider ? (
              <div className="flex flex-wrap gap-2">
                <Button
                  type="button"
                  disabled={isLoadingProviders}
                  onClick={() => {
                    onOpenProviderSetup("codegraff", "codegraff_device");
                  }}
                >
                  Connect Codegraff
                </Button>
                <Button
                  type="button"
                  variant="outline"
                  disabled={isLoadingProviders}
                  onClick={() => {
                    onOpenProviderSetup("codex", "codex_device");
                  }}
                >
                  Use Codex
                </Button>
                <Button
                  type="button"
                  variant="outline"
                  disabled={apiKeyProvider == null || isLoadingProviders}
                  onClick={() => {
                    if (apiKeyProvider != null) {
                      onOpenProviderSetup(apiKeyProvider, "api_key");
                    }
                  }}
                >
                  Use API key
                </Button>
              </div>
            ) : null}
          </ChecklistItem>

          <ChecklistItem
            complete={hasWorkspace}
            description={
              hasWorkspace
                ? "Workspace selected."
                : "Open a local folder, clone a repository, or create a project."
            }
            icon={FolderOpen}
            title="Choose workspace"
          >
            {!hasWorkspace ? (
              <div className="flex flex-wrap gap-2">
                <Button
                  type="button"
                  variant="outline"
                  disabled={isBusy}
                  onClick={onOpenFolder}
                >
                  <FolderOpen data-icon="inline-start" />
                  Open folder
                </Button>
                <Button
                  type="button"
                  variant="outline"
                  disabled={isBusy}
                  onClick={onOpenClone}
                >
                  <GitBranchPlus data-icon="inline-start" />
                  Clone from Git
                </Button>
                <Button
                  type="button"
                  variant="outline"
                  disabled={isBusy}
                  onClick={onOpenQuickStart}
                >
                  <Rocket data-icon="inline-start" />
                  Quick start
                </Button>
              </div>
            ) : null}
          </ChecklistItem>

          <ChecklistItem
            complete={isComplete}
            description={
              isComplete
                ? "Composer is ready."
                : "Ready after provider and workspace are set."
            }
            icon={MessageSquareText}
            title="Start chat"
          >
            {isComplete ? (
              <Button type="button" onClick={onFocusPrompt}>
                Focus prompt
              </Button>
            ) : null}
          </ChecklistItem>
        </div>
      </CardContent>
    </Card>
  );
}

function ChecklistItem({
  children,
  complete,
  description,
  icon: Icon,
  title,
}: {
  children?: ReactNode;
  complete: boolean;
  description: string;
  icon: ComponentType<{ className?: string }>;
  title: string;
}) {
  const StatusIcon = complete ? CheckCircle2 : Circle;

  return (
    <div
      className={cn(
        "grid gap-3 rounded-lg border border-border/70 bg-background/60 p-3 sm:grid-cols-[auto_1fr]",
        complete ? "border-accent/30" : null,
      )}
    >
      <div className="flex items-center gap-2 text-muted-foreground">
        <StatusIcon
          className={cn("size-4", complete ? "text-accent" : null)}
        />
        <Icon className="size-4" />
      </div>
      <div className="min-w-0">
        <div className="text-sm font-medium text-foreground">{title}</div>
        <p className="mt-0.5 text-xs/relaxed text-muted-foreground">
          {description}
        </p>
        {children ? <div className="mt-3">{children}</div> : null}
      </div>
    </div>
  );
}

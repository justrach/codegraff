import {
  FolderOpen,
  GitBranchPlus,
  Rocket,
  type LucideIcon,
} from "lucide-react";

import {
  Card,
  CardAction,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/Card";

export function NewChatLaunchActions({
  isBusy,
  isOpeningProject,
  onOpenClone,
  onOpenFolder,
  onOpenQuickStart,
}: {
  isBusy: boolean;
  isOpeningProject: boolean;
  onOpenClone: () => void;
  onOpenFolder: () => void;
  onOpenQuickStart: () => void;
}) {
  return (
    <div className="grid w-full max-w-3xl grid-cols-1 gap-3 sm:grid-cols-3">
      <LaunchCard
        description="Pick a local folder and open it as the active workspace."
        disabled={isBusy}
        icon={FolderOpen}
        label={isOpeningProject ? "Opening..." : "Open folder"}
        onClick={onOpenFolder}
      />
      <LaunchCard
        description="Clone a repository and jump straight into a new chat."
        disabled={isBusy}
        icon={GitBranchPlus}
        label="Clone from Git"
        onClick={onOpenClone}
      />
      <LaunchCard
        description="Create a fresh GitHub repo, clone it locally, and open it."
        disabled={isBusy}
        icon={Rocket}
        label="Quick start"
        onClick={onOpenQuickStart}
      />
    </div>
  );
}

function LaunchCard({
  description,
  disabled,
  icon: Icon,
  label,
  onClick,
}: {
  description: string;
  disabled: boolean;
  icon: LucideIcon;
  label: string;
  onClick: () => void;
}) {
  return (
    <button
      type="button"
      className="block w-full appearance-none text-left disabled:cursor-not-allowed"
      onClick={onClick}
      disabled={disabled}
    >
      <Card
        size="sm"
        className="h-full border border-border bg-card transition-colors hover:border-accent/40 hover:bg-secondary"
      >
        <CardHeader className="gap-2">
          <CardAction className="justify-self-start">
            <div className="flex size-8 items-center justify-center rounded-md border border-accent/20 bg-accent/10 text-accent">
              <Icon strokeWidth={2} className="size-4" />
            </div>
          </CardAction>
          <CardTitle>{label}</CardTitle>
          <CardDescription>{description}</CardDescription>
        </CardHeader>
      </Card>
    </button>
  );
}

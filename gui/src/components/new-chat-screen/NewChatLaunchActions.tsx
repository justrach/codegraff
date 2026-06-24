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
        className="h-full rounded-2xl border border-border/80 bg-card/80 shadow-[0_18px_55px_-38px_color-mix(in_oklab,var(--foreground)_55%,transparent),inset_0_1px_0_color-mix(in_oklab,var(--background)_75%,transparent)] backdrop-blur transition-all duration-200 hover:-translate-y-0.5 hover:border-accent/45 hover:bg-card hover:shadow-[0_22px_70px_-36px_color-mix(in_oklab,var(--foreground)_65%,transparent)]"
      >
        <CardHeader className="gap-2">
          <CardAction className="justify-self-start">
            <div className="flex size-9 items-center justify-center rounded-xl border border-accent/25 bg-accent/10 text-accent shadow-[inset_0_1px_0_color-mix(in_oklab,var(--background)_70%,transparent)]">
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

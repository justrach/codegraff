import {
  ArrowUpIcon,
  ChevronDownIcon,
  MapIcon,
  SparklesIcon,
  SquareIcon,
  ZapIcon,
} from "lucide-react";

import { Button } from "@/components/ui/Button";
import { ButtonGroup } from "@/components/ui/ButtonGroup";
import { CardFooter } from "@/components/ui/Card";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuGroup,
  DropdownMenuRadioGroup,
  DropdownMenuRadioItem,
  DropdownMenuTrigger,
} from "@/components/ui/DropdownMenu";
import { Input } from "@/components/ui/Input";
import { Throbber } from "@/components/ui/Throbber";
import type { PromptModelOption } from "@/services/desktop/types/contracts";
import { cn } from "@/utils/cn";
import { formatReasoningEffortLabel } from "@/utils/reasoning";

interface PromptControlBarProps {
  fastApplies: boolean;
  fastEnabled: boolean;
  hasAvailableModels: boolean;
  isControlDisabled: boolean;
  isModelMenuOpen: boolean;
  isPlanningMode: boolean;
  isSubmitDisabled: boolean;
  isUltraMode: boolean;
  isWorking: boolean;
  modelSearchQuery: string;
  planningThinkingLabel: string;
  selectedModelLabel: string;
  selectedModelValue: string;
  selectedReasoning: string | null;
  selectedReasoningEfforts: string[];
  visibleModels: PromptModelOption[];
  onFastToggle: () => void;
  onModelChange: (value: string) => void;
  onModelMenuOpenChange: (open: boolean) => void;
  onPlanningModeToggle: () => void;
  onPrimaryAction: () => void;
  onReasoningChange: (value: string) => void;
  onSearchQueryChange: (value: string) => void;
  onUltraModeToggle: () => void;
}

export function PromptControlBar({
  fastApplies,
  fastEnabled,
  hasAvailableModels,
  isControlDisabled,
  isModelMenuOpen,
  isPlanningMode,
  isSubmitDisabled,
  isUltraMode,
  isWorking,
  modelSearchQuery,
  planningThinkingLabel,
  selectedModelLabel,
  selectedModelValue,
  selectedReasoning,
  selectedReasoningEfforts,
  visibleModels,
  onFastToggle,
  onModelChange,
  onModelMenuOpenChange,
  onPlanningModeToggle,
  onPrimaryAction,
  onReasoningChange,
  onSearchQueryChange,
  onUltraModeToggle,
}: PromptControlBarProps) {
  return (
    <CardFooter className="relative z-10 items-center justify-between p-0">
      <ButtonGroup aria-label="Prompt controls" className="-mb-1.5">
        <DropdownMenu
          open={isModelMenuOpen}
          onOpenChange={onModelMenuOpenChange}
        >
          <DropdownMenuTrigger
            render={
              <Button
                type="button"
                variant="outline"
                size="sm"
                className="min-w-0 max-w-44 overflow-hidden text-muted-foreground hover:bg-transparent hover:text-foreground"
                disabled={isControlDisabled || !hasAvailableModels}
                title={selectedModelLabel}
              />
            }
          >
            <span className="min-w-0 truncate">{selectedModelLabel}</span>
            <ChevronDownIcon className="shrink-0" />
          </DropdownMenuTrigger>
          <DropdownMenuContent align="start" className="max-h-80 w-72 pt-0">
            <div className="sticky z-10 top-0 bg-popover -mx-1 p-1.5">
              <Input
                value={modelSearchQuery}
                placeholder="Search models"
                className="h-8 bg-popover dark:bg-popover"
                autoFocus
                onChange={(event) => onSearchQueryChange(event.target.value)}
                onKeyDown={(event) => event.stopPropagation()}
              />
            </div>
            <DropdownMenuGroup>
              <DropdownMenuRadioGroup
                value={selectedModelValue}
                onValueChange={onModelChange}
              >
                {visibleModels.length === 0 ? (
                  <div className="px-2 py-1.5 text-xs text-muted-foreground">
                    No models match your search.
                  </div>
                ) : (
                  visibleModels.map((option) => (
                    <DropdownMenuRadioItem
                      key={`${option.providerId}:${option.modelId}`}
                      value={`${option.providerId}:${option.modelId}`}
                    >
                      <span className="truncate">
                        {option.modelName ?? option.modelId}
                      </span>
                      <span className="ml-auto text-muted-foreground">
                        {option.providerName}
                      </span>
                    </DropdownMenuRadioItem>
                  ))
                )}
              </DropdownMenuRadioGroup>
            </DropdownMenuGroup>
          </DropdownMenuContent>
        </DropdownMenu>

        <DropdownMenu>
          <DropdownMenuTrigger
            render={
              <Button
                type="button"
                variant="outline"
                size="sm"
                className="text-muted-foreground hover:bg-transparent hover:text-foreground"
                disabled={
                  isControlDisabled || selectedReasoningEfforts.length === 0
                }
              />
            }
          >
            <span>
              {selectedReasoning == null
                ? "Reasoning"
                : formatReasoningEffortLabel(selectedReasoning)}
            </span>
            <ChevronDownIcon />
          </DropdownMenuTrigger>
          <DropdownMenuContent align="start" className="w-40">
            <DropdownMenuGroup>
              <DropdownMenuRadioGroup
                value={selectedReasoning ?? ""}
                onValueChange={onReasoningChange}
              >
                {selectedReasoningEfforts.map((option) => (
                  <DropdownMenuRadioItem key={option} value={option}>
                    {formatReasoningEffortLabel(option)}
                  </DropdownMenuRadioItem>
                ))}
              </DropdownMenuRadioGroup>
            </DropdownMenuGroup>
          </DropdownMenuContent>
        </DropdownMenu>
        <Button
          type="button"
          variant="outline"
          size="sm"
          aria-label="Toggle planning mode"
          aria-pressed={isPlanningMode}
          className={cn(
            "text-muted-foreground hover:bg-transparent hover:text-foreground",
            isPlanningMode &&
              "border-[color:var(--accent)] bg-[color:color-mix(in_oklab,var(--accent)_10%,transparent)] text-foreground hover:bg-[color:color-mix(in_oklab,var(--accent)_14%,transparent)]",
          )}
          disabled={isControlDisabled}
          onClick={onPlanningModeToggle}
        >
          <MapIcon data-icon="inline-start" />
          <span className="text-xs">Plan</span>
        </Button>
        <Button
          type="button"
          variant="outline"
          size="sm"
          aria-label="Toggle fast mode"
          aria-pressed={fastApplies && fastEnabled}
          className={cn(
            "text-muted-foreground hover:bg-transparent hover:text-foreground",
            fastApplies &&
              fastEnabled &&
              "border-[color:var(--accent)] bg-[color:color-mix(in_oklab,var(--accent)_10%,transparent)] text-foreground hover:bg-[color:color-mix(in_oklab,var(--accent)_14%,transparent)]",
          )}
          disabled={isControlDisabled || !fastApplies}
          onClick={onFastToggle}
          title={
            fastApplies
              ? "Codex priority service tier — lower latency"
              : "Fast (priority) — codex only"
          }
        >
          <ZapIcon data-icon="inline-start" />
          <span className="text-xs">Fast</span>
        </Button>
        <Button
          type="button"
          variant="outline"
          size="sm"
          aria-label="Toggle Ultra mode"
          aria-pressed={isUltraMode}
          className={cn(
            "text-muted-foreground hover:bg-transparent hover:text-foreground",
            isUltraMode &&
              "border-[color:var(--accent)] bg-[color:color-mix(in_oklab,var(--accent)_12%,transparent)] text-foreground shadow-[0_0_12px_-3px_color-mix(in_oklab,var(--accent)_75%,transparent)] hover:bg-[color:color-mix(in_oklab,var(--accent)_16%,transparent)]",
          )}
          disabled={isControlDisabled}
          onClick={onUltraModeToggle}
          title="Ultra — engage the ultracode codeword: fan out parallel agents for this turn"
        >
          <SparklesIcon
            data-icon="inline-start"
            className={cn(isUltraMode && "text-[color:var(--accent)]")}
          />
          <span className="text-xs">Ultra</span>
        </Button>
        {isPlanningMode ? (
          <span
            className="inline-flex h-8 items-center gap-2 px-1.5 text-xs font-medium text-muted-foreground"
            title="Planning uses the thinking agent"
          >
            <Throbber
              variant="pulse"
              className="text-[color:var(--accent)]"
            />
            {planningThinkingLabel}
          </span>
        ) : null}
      </ButtonGroup>
      <Button
        type="button"
        size="icon-lg"
        className={cn(
          "rounded-full transition-shadow",
          isUltraMode &&
            "shadow-[0_0_18px_-2px_color-mix(in_oklab,var(--accent)_70%,transparent)] ring-2 ring-[color:color-mix(in_oklab,var(--accent)_45%,transparent)]",
        )}
        aria-label={isWorking && isSubmitDisabled ? "Stop" : "Send"}
        onClick={onPrimaryAction}
        disabled={isWorking ? false : isSubmitDisabled}
      >
        {isWorking && isSubmitDisabled ? <SquareIcon /> : <ArrowUpIcon />}
      </Button>
    </CardFooter>
  );
}

import { useEffect, useRef, useState } from "react";
import {
  ArrowUpIcon,
  ChevronDownIcon,
  MapIcon,
  SquareIcon,
  ZapIcon,
} from "lucide-react";

import { Button } from "@/components/ui/Button";
import { ButtonGroup } from "@/components/ui/ButtonGroup";
import {
  Card,
  CardContent,
  CardDescription,
  CardFooter,
  CardHeader,
  CardTitle,
} from "@/components/ui/Card";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuGroup,
  DropdownMenuRadioGroup,
  DropdownMenuRadioItem,
  DropdownMenuTrigger,
} from "@/components/ui/DropdownMenu";
import { Input } from "@/components/ui/Input";
import { Textarea } from "@/components/ui/Textarea";
import { Throbber } from "@/components/ui/Throbber";
import { CommandAutocomplete } from "@/components/CommandAutocomplete";
import { AttachmentTray } from "@/components/attachments/AttachmentTray";
import { DropOverlay } from "@/components/attachments/DropOverlay";
import { classifyPath } from "@/components/attachments/attachmentTypes";
import { useAutosizeTextarea } from "@/hooks/useAutosizeTextarea";
import { useAttachments } from "@/hooks/useSession";
import { useCommandAutocomplete } from "@/hooks/useCommandAutocomplete";
import { useDropZone } from "@/hooks/useFileDrop";
import { usePromptModelPicker } from "@/hooks/usePromptModelPicker";
import { savePastedImage, setFast } from "@/services/desktop/client";
import { cn } from "@/utils/cn";
import {
  formatPlanningThinkingLabel,
  formatReasoningEffortLabel,
} from "@/utils/reasoning";
import type { PromptInputCardProps } from "./types/prompt";

export function PromptInputCard({
  canCompose,
  isRequestActive,
  isSendingPrompt,
  isPlanningMode,
  placeholder = "Ask about this workspace…",
  promptSettings,
  promptDraft,
  isInputDisabled = false,
  binding,
  workspacePath,
  onCommandSelect,
  setPlanningMode,
  setPromptDraft,
  stopPrompt,
  submitPrompt,
  updatePromptSettings,
}: PromptInputCardProps) {
  const textareaRef = useRef<HTMLTextAreaElement | null>(null);
  const dropZoneRef = useRef<HTMLDivElement | null>(null);
  const { attachments, addAttachments, removeAttachment } =
    useAttachments(binding);
  const { isActive: isDropActive } = useDropZone(dropZoneRef, (paths) => {
    const accepted = paths
      .map((path) => classifyPath(path))
      .filter((item): item is NonNullable<typeof item> => item != null);
    addAttachments(accepted);
  });
  const isControlDisabled =
    isSendingPrompt || isRequestActive || !canCompose || isInputDisabled;
  const isWorking = isRequestActive;
  const isSubmitDisabled =
    !canCompose ||
    isSendingPrompt ||
    isInputDisabled ||
    promptDraft.trim().length === 0;
  const {
    handleModelChange,
    handleModelMenuOpenChange,
    handleReasoningChange,
    hasAvailableModels,
    isModelMenuOpen,
    modelSearchQuery,
    selectedModel,
    selectedModelValue,
    selectedReasoning,
    selectedReasoningEfforts,
    setModelSearchQuery,
    visibleModels,
  } = usePromptModelPicker({
    promptSettings,
    updatePromptSettings,
  });

  const [fastEnabled, setFastEnabled] = useState(
    promptSettings?.fastEnabled ?? false,
  );
  useEffect(() => {
    setFastEnabled(promptSettings?.fastEnabled ?? false);
  }, [promptSettings?.fastEnabled]);
  const isCodexModel = selectedModel?.providerId === "codex";

  function handleFastToggle() {
    const next = !fastEnabled;
    setFastEnabled(next);
    void setFast(next);
  }

  function handleAutocompleteSelect(command: Parameters<typeof onCommandSelect>[0]) {
    // The model picker lives in this component, so handle `/model` here rather
    // than routing it up.
    if (command.name === "model") {
      setPromptDraft("");
      handleModelMenuOpenChange(true);
      return;
    }
    onCommandSelect(command);
  }

  const commandAutocomplete = useCommandAutocomplete({
    promptDraft,
    setPromptDraft,
    workspacePath,
    enabled: canCompose && !isInputDisabled,
    onSelect: handleAutocompleteSelect,
  });

  useAutosizeTextarea(textareaRef, promptDraft);

  // Highlight a leading slash-command token so the user sees they're issuing a
  // command. Only active in command mode, so normal prose typing is untouched.
  const commandMatch = /^(\/[A-Za-z][\w-]*)([\s\S]*)$/.exec(promptDraft);
  const planningThinkingLabel = formatPlanningThinkingLabel();
  const selectedModelLabel =
    selectedModel?.modelName ?? selectedModel?.modelId ?? "Model";

  function handleSubmit() {
    if (isSubmitDisabled) {
      return;
    }

    void submitPrompt();
  }

  function handlePrimaryAction() {
    if (isWorking) {
      void stopPrompt();
      return;
    }

    handleSubmit();
  }

  function handlePlanningModeToggle() {
    setPlanningMode(!isPlanningMode);
  }

  // Cmd/Ctrl+V of an image: persist the clipboard bytes to a temp file and add
  // it through the same attachment pipeline as a drag-dropped file.
  async function handlePaste(
    event: React.ClipboardEvent<HTMLTextAreaElement>,
  ) {
    const items = event.clipboardData?.items;
    if (!items) {
      return;
    }
    for (const item of items) {
      if (item.kind !== "file" || !item.type.startsWith("image/")) {
        continue;
      }
      const file = item.getAsFile();
      if (!file) {
        continue;
      }
      event.preventDefault();
      try {
        const bytes = Array.from(new Uint8Array(await file.arrayBuffer()));
        const ext = item.type.split("/")[1] ?? "png";
        const path = await savePastedImage(bytes, ext);
        const attachment = classifyPath(path);
        if (attachment) {
          addAttachments([attachment]);
        }
      } catch (error) {
        console.error("Failed to attach pasted image", error);
      }
      return;
    }
  }

  return (
    <div ref={dropZoneRef} className="relative mx-auto w-full max-w-3xl">
      {isDropActive ? <DropOverlay /> : null}
      {commandAutocomplete.isOpen ? (
        <CommandAutocomplete
          items={commandAutocomplete.items}
          activeIndex={commandAutocomplete.activeIndex}
          onHighlight={commandAutocomplete.setActiveIndex}
          onPick={commandAutocomplete.pick}
        />
      ) : null}
      <Card
        className={cn(
          "relative gap-0 rounded-2xl border border-border bg-background/50 p-2 transition-colors transition-shadow ring-0",
          isPlanningMode &&
            "border-[color:var(--accent)] ring-5 ring-[color:color-mix(in_oklab,var(--accent)_14%,transparent)] border-dashed",
        )}
      >
        <CardHeader className="sr-only">
          <CardTitle>Prompt</CardTitle>
          <CardDescription>Ask about the current workspace.</CardDescription>
        </CardHeader>
        <CardContent className="relative z-10 p-0">
          {attachments.length > 0 ? (
            <AttachmentTray
              attachments={attachments}
              onRemove={removeAttachment}
              className="m-1 mb-2"
            />
          ) : null}
          <div className="relative m-1">
            {commandMatch ? (
              <div
                aria-hidden
                className="pointer-events-none absolute inset-0 max-h-80 overflow-hidden whitespace-pre-wrap break-words text-sm"
              >
                <span className="font-medium text-[color:var(--accent)]">
                  {commandMatch[1]}
                </span>
                <span className="text-foreground">{commandMatch[2]}</span>
              </div>
            ) : null}
            <Textarea
              ref={textareaRef}
              id="prompt"
              className={cn(
                "max-h-80 overflow-y-auto rounded-none border-0 bg-transparent px-0 py-0 text-sm shadow-none outline-none ring-0 placeholder:text-muted-foreground/80 focus-visible:border-transparent focus-visible:ring-0 focus-visible:ring-offset-0 dark:bg-transparent",
                commandMatch && "text-transparent caret-[color:var(--foreground)]",
              )}
              placeholder={placeholder}
              value={promptDraft}
              onChange={(event) => setPromptDraft(event.target.value)}
              onPaste={handlePaste}
              onKeyDown={(event) => {
                // The command menu consumes Enter/Tab/arrows while open, so a
                // command is completed rather than sent.
                if (commandAutocomplete.handleKeyDown(event)) {
                  return;
                }
                if (event.key !== "Enter") {
                  return;
                }
                // Shift+Enter and Alt/Option+Enter insert a newline instead of
                // sending.
                if (event.shiftKey) {
                  return;
                }
                if (event.altKey) {
                  event.preventDefault();
                  document.execCommand("insertText", false, "\n");
                  return;
                }
                // Don't submit mid-IME-composition (e.g. selecting a candidate).
                if (event.nativeEvent.isComposing) {
                  return;
                }
                event.preventDefault();
                if (!isSubmitDisabled) {
                  handleSubmit();
                }
              }}
              disabled={isControlDisabled}
              rows={3}
            />
          </div>
        </CardContent>
        <CardFooter className="relative z-10 items-center justify-between p-0">
          <ButtonGroup aria-label="Prompt controls" className="-mb-1.5">
            <DropdownMenu
              open={isModelMenuOpen}
              onOpenChange={handleModelMenuOpenChange}
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
                    onChange={(event) => {
                      setModelSearchQuery(event.target.value);
                    }}
                    onKeyDown={(event) => {
                      event.stopPropagation();
                    }}
                  />
                </div>
                <DropdownMenuGroup>
                  <DropdownMenuRadioGroup
                    value={selectedModelValue}
                    onValueChange={handleModelChange}
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
                    onValueChange={handleReasoningChange}
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
              onClick={handlePlanningModeToggle}
            >
              <MapIcon data-icon="inline-start" />
              <span className="text-xs">Plan</span>
            </Button>
            {isCodexModel ? (
              <Button
                type="button"
                variant="outline"
                size="sm"
                aria-label="Toggle fast mode"
                aria-pressed={fastEnabled}
                className={cn(
                  "text-muted-foreground hover:bg-transparent hover:text-foreground",
                  fastEnabled &&
                    "border-[color:var(--accent)] bg-[color:color-mix(in_oklab,var(--accent)_10%,transparent)] text-foreground hover:bg-[color:color-mix(in_oklab,var(--accent)_14%,transparent)]",
                )}
                disabled={isControlDisabled}
                onClick={handleFastToggle}
                title="Codex priority service tier — lower latency"
              >
                <ZapIcon data-icon="inline-start" />
                <span className="text-xs">Fast</span>
              </Button>
            ) : null}
            {isPlanningMode ? (
              <span
                className="inline-flex h-8 items-center gap-2 px-1.5 text-xs font-medium text-muted-foreground"
                title="Planning uses the thinking agent"
              >
                <Throbber variant="pulse" className="text-[color:var(--accent)]" />
                {planningThinkingLabel}
              </span>
            ) : null}
          </ButtonGroup>
          <Button
            type="button"
            size="icon-lg"
            className="rounded-full"
            aria-label={isWorking ? "Stop" : "Send"}
            onClick={handlePrimaryAction}
            disabled={isWorking ? false : isSubmitDisabled}
          >
            {isWorking ? <SquareIcon /> : <ArrowUpIcon />}
          </Button>
        </CardFooter>
      </Card>
    </div>
  );
}

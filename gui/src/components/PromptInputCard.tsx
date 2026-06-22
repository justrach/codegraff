import {
  useEffect,
  useRef,
  useState,
  type ClipboardEvent,
  type KeyboardEvent,
} from "react";
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
import {
  extractAttachmentTransferItems,
  filterSupportedAttachmentTransferItems,
  getAttachmentTransferFileName,
  type AttachmentTransferItem,
} from "@/components/attachments/attachmentTransfer";
import {
  classifyPath,
  parseAttachmentBlock,
  type Attachment,
} from "@/components/attachments/attachmentTypes";
import { parseChoiceCommand } from "@/components/commandChoices";
import { useAutosizeTextarea } from "@/hooks/useAutosizeTextarea";
import { useAttachments } from "@/hooks/useSession";
import { useCommandAutocomplete } from "@/hooks/useCommandAutocomplete";
import { useDropZone } from "@/hooks/useFileDrop";
import { usePromptModelPicker } from "@/hooks/usePromptModelPicker";
import { saveAttachmentFile, setFast } from "@/services/desktop/client";
import { cn } from "@/utils/cn";
import {
  getPromptHistoryNavigationResult,
  type PromptHistoryCursor,
} from "./promptHistoryNavigation";
import {
  formatPlanningThinkingLabel,
  formatReasoningEffortLabel,
} from "@/utils/reasoning";
import type { PromptInputCardProps } from "./types/prompt";

const EMPTY_PROMPT_HISTORY: string[] = [];

interface PlanningModeShortcutEvent {
  key: string;
  shiftKey: boolean;
  altKey: boolean;
  ctrlKey: boolean;
  metaKey: boolean;
}

export function shouldHandlePlanningModeShortcut(
  event: PlanningModeShortcutEvent,
  isDisabled: boolean,
): boolean {
  return (
    !isDisabled &&
    event.key === "Tab" &&
    event.shiftKey &&
    !event.altKey &&
    !event.ctrlKey &&
    !event.metaKey
  );
}

function isCaretOnFirstLine(textarea: HTMLTextAreaElement) {
  return !textarea.value.slice(0, textarea.selectionStart).includes("\n");
}

function isCaretOnLastLine(textarea: HTMLTextAreaElement) {
  return !textarea.value.slice(textarea.selectionEnd).includes("\n");
}

function arrayBufferToBase64(buffer: ArrayBuffer): string {
  const bytes = new Uint8Array(buffer);
  let binary = "";
  const chunkSize = 0x8000;
  for (let index = 0; index < bytes.length; index += chunkSize) {
    binary += String.fromCharCode(...bytes.subarray(index, index + chunkSize));
  }
  return btoa(binary);
}

export function PromptInputCard({
  canCompose,
  isRequestActive,
  isSendingPrompt,
  isPlanningMode,
  isUltraMode,
  placeholder = "Ask about this workspace…",
  promptSettings,
  promptDraft,
  queuedPrompts = [],
  promptHistory = EMPTY_PROMPT_HISTORY,
  focusSignal,
  isInputDisabled = false,
  binding,
  workspacePath,
  onCommandSelect,
  setPlanningMode,
  setUltraMode,
  setPromptDraft,
  stopPrompt,
  submitPrompt,
  updatePromptSettings,
}: PromptInputCardProps) {
  const textareaRef = useRef<HTMLTextAreaElement | null>(null);
  // The transparent-text overlay must scroll in lockstep with the textarea so the
  // highlighted slash-command token stays aligned when the draft exceeds max-h-80
  // and the textarea becomes scrollable. Without syncing, the overlay (overflow-
  // hidden, pinned to inset-0) stays put while the textarea content scrolls under
  // it — the highlight drifts away from the caret.
  const commandOverlayRef = useRef<HTMLDivElement | null>(null);
  const dropZoneRef = useRef<HTMLDivElement | null>(null);
  const handledPasteAtRef = useRef(0);
  const { attachments, addAttachments, removeAttachment, replaceAttachments } =
    useAttachments(binding);
  const { isActive: isDropActive } = useDropZone(dropZoneRef, (items) => {
    void attachTransferItems(items);
  });
  const canQueueFollowup = isRequestActive && !isInputDisabled;
  const canEditPrompt = canCompose || canQueueFollowup;
  const isControlDisabled =
    isSendingPrompt || isRequestActive || !canCompose || isInputDisabled;
  // Keep the composer editable while a request streams so the user can draft
  // and queue the next message. While streaming, a non-empty draft turns the
  // primary button back into Send; an empty draft keeps it as Stop.
  const isTextareaDisabled = !canEditPrompt || isInputDisabled;
  const isWorking = isRequestActive;
  const isQueueSubmit = isWorking;
  function canSubmitDraft(value: string) {
    return !(
      isInputDisabled ||
      (!canCompose && !isQueueSubmit) ||
      (!isQueueSubmit && isSendingPrompt) ||
      (isQueueSubmit && !canQueueFollowup) ||
      value.trim().length === 0
    );
  }
  const isSubmitDisabled =
    isInputDisabled ||
    (!canCompose && !isQueueSubmit) ||
    (!isQueueSubmit && isSendingPrompt) ||
    (isQueueSubmit && !canQueueFollowup) ||
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
  const [historyCursor, setHistoryCursor] = useState<PromptHistoryCursor>(null);
  const [draftBeforeHistory, setDraftBeforeHistory] = useState("");
  // Live attachment tray captured when entering history, restored on the way out.
  const [attachmentsBeforeHistory, setAttachmentsBeforeHistory] = useState<
    Attachment[]
  >([]);
  const promptHistoryLengthRef = useRef(promptHistory.length);

  function resetHistoryNavigation() {
    setHistoryCursor(null);
    setDraftBeforeHistory("");
    setAttachmentsBeforeHistory([]);
  }

  useEffect(() => {
    setFastEnabled(promptSettings?.fastEnabled ?? false);
  }, [promptSettings?.fastEnabled]);

  // Whether /fast actually changes harness behavior. The harness only applies
  // the priority service tier on the codex provider (the `responses` kind); it
  // is a no-op everywhere else. The runtime reports this authoritatively via
  // `fastApplies`, so the toggle stays active only when it's true.
  const fastApplies = promptSettings?.fastApplies ?? false;

  function handleFastToggle() {
    if (!fastApplies) return;
    const next = !fastEnabled;
    setFastEnabled(next);
    void setFast(next);
  }

  function handleAutocompleteSelect(
    command: Parameters<typeof onCommandSelect>[0],
  ) {
    // The model picker lives in this component, so handle `/model` here rather
    // than routing it up.
    if (command.name === "model") {
      setPromptDraft("");
      handleModelMenuOpenChange(true);
      return;
    }
    // `/ultracode` expands into on/off choice rows; selecting one flips the same
    // ultra toggle the footer button uses (a GUI-only mode, not a backend cmd).
    const choice = parseChoiceCommand(command.name);
    if (choice != null && choice.name === "ultracode") {
      setUltraMode(choice.arg === "on");
      setPromptDraft("");
      return;
    }
    onCommandSelect(command);
  }

  const commandAutocomplete = useCommandAutocomplete({
    promptDraft,
    setPromptDraft,
    workspacePath,
    enabled: canEditPrompt && !isInputDisabled,
    ultracodeEnabled: isUltraMode,
    onSelect: handleAutocompleteSelect,
  });

  useAutosizeTextarea(textareaRef, promptDraft);

  useEffect(() => {
    if (focusSignal == null || isTextareaDisabled) {
      return;
    }
    textareaRef.current?.focus();
  }, [focusSignal, isTextareaDisabled]);

  // Highlight a leading slash-command token so the user sees they're issuing a
  // command. Only active in command mode, so normal prose typing is untouched.
  const commandMatch = /^(\/[A-Za-z][\w-]*)([\s\S]*)$/.exec(promptDraft);
  const planningThinkingLabel = formatPlanningThinkingLabel();
  const selectedModelLabel =
    selectedModel?.modelName ?? selectedModel?.modelId ?? "Model";

  async function saveTransferFile(file: File): Promise<string | null> {
    try {
      return await saveAttachmentFile({
        name: getAttachmentTransferFileName(file),
        dataBase64: arrayBufferToBase64(await file.arrayBuffer()),
      });
    } catch (error) {
      console.error("Failed to save attachment file", error);
      return null;
    }
  }

  async function attachTransferItems(items: AttachmentTransferItem[]) {
    const supportedItems = filterSupportedAttachmentTransferItems(items);
    if (supportedItems.length === 0) {
      return;
    }

    const accepted: NonNullable<ReturnType<typeof classifyPath>>[] = [];
    for (const item of supportedItems) {
      const path =
        item.kind === "path" ? item.path : await saveTransferFile(item.file);
      if (path == null) {
        continue;
      }
      const attachment = classifyPath(path);
      if (attachment != null) {
        accepted.push(attachment);
      }
    }

    if (accepted.length > 0) {
      addAttachments(accepted);
    }
  }

  function handleSubmit(draftOverride = promptDraft) {
    if (!canSubmitDraft(draftOverride)) {
      return;
    }

    resetHistoryNavigation();
    if (draftOverride !== promptDraft) {
      setPromptDraft(draftOverride);
    }
    void submitPrompt(draftOverride);
  }

  function handleDraftChange(value: string) {
    resetHistoryNavigation();
    setPromptDraft(value);
  }

  function moveCaretToEndOnNextFrame() {
    requestAnimationFrame(() => {
      const textarea = textareaRef.current;
      if (textarea == null) {
        return;
      }

      const end = textarea.value.length;
      textarea.setSelectionRange(end, end);
    });
  }

  function handleHistoryNavigation(event: KeyboardEvent<HTMLTextAreaElement>) {
    if (
      event.nativeEvent.isComposing ||
      event.altKey ||
      event.ctrlKey ||
      event.metaKey ||
      event.shiftKey
    ) {
      return false;
    }

    const direction =
      event.key === "ArrowUp"
        ? "previous"
        : event.key === "ArrowDown"
          ? "next"
          : null;
    if (direction == null) {
      return false;
    }

    const textarea = event.currentTarget;
    if (direction === "previous" && !isCaretOnFirstLine(textarea)) {
      return false;
    }
    if (direction === "next" && !isCaretOnLastLine(textarea)) {
      return false;
    }

    const didHistoryLengthChange =
      promptHistoryLengthRef.current !== promptHistory.length;
    const effectiveCursor = didHistoryLengthChange ? null : historyCursor;
    const effectiveDraftBeforeHistory = didHistoryLengthChange
      ? ""
      : draftBeforeHistory;
    promptHistoryLengthRef.current = promptHistory.length;

    const result = getPromptHistoryNavigationResult({
      direction,
      promptHistory,
      cursor: effectiveCursor,
      currentDraft: promptDraft,
      draftBeforeHistory: effectiveDraftBeforeHistory,
    });
    if (result == null) {
      return false;
    }

    event.preventDefault();

    // Mirror the draft preservation for attachments: snapshot the live tray when
    // entering history so ArrowDown back out restores it, and rehydrate the
    // attachment cards from the stored `Attached files:` block on each entry.
    const enteringHistory = effectiveCursor == null && result.cursor != null;
    if (enteringHistory) {
      setAttachmentsBeforeHistory(attachments);
    }

    setHistoryCursor(result.cursor);
    setDraftBeforeHistory(result.draftBeforeHistory);

    if (result.cursor == null) {
      // Exited history — restore the live draft and its attachments.
      setPromptDraft(result.draft);
      replaceAttachments(attachmentsBeforeHistory);
      setAttachmentsBeforeHistory([]);
    } else {
      const { body, paths } = parseAttachmentBlock(result.draft);
      setPromptDraft(body);
      replaceAttachments(
        paths
          .map((path) => classifyPath(path))
          .filter((item): item is Attachment => item != null),
      );
    }
    moveCaretToEndOnNextFrame();
    return true;
  }

  function handlePrimaryAction() {
    const currentDraft = textareaRef.current?.value ?? promptDraft;
    if (canSubmitDraft(currentDraft)) {
      handleSubmit(currentDraft);
      return;
    }

    if (isWorking) {
      void stopPrompt();
    }
  }

  function handlePlanningModeToggle() {
    setPlanningMode(!isPlanningMode);
  }

  function handlePlanningModeShortcut(
    event: KeyboardEvent<HTMLTextAreaElement>,
  ) {
    if (!shouldHandlePlanningModeShortcut(event, isControlDisabled)) {
      return;
    }

    event.preventDefault();
    setPlanningMode(!isPlanningMode);
  }

  function scheduleClipboardTextPasteFallback(
    event: KeyboardEvent<HTMLTextAreaElement>,
  ) {
    if (
      isTextareaDisabled ||
      event.nativeEvent.isComposing ||
      event.altKey ||
      (!event.metaKey && !event.ctrlKey) ||
      event.key.toLowerCase() !== "v" ||
      navigator.clipboard?.readText == null
    ) {
      return;
    }

    const textarea = event.currentTarget;
    const beforeValue = textarea.value;
    const selectionStart = textarea.selectionStart;
    const selectionEnd = textarea.selectionEnd;

    window.setTimeout(() => {
      if (
        Date.now() - handledPasteAtRef.current < 500 ||
        textareaRef.current !== textarea ||
        textarea.value !== beforeValue
      ) {
        return;
      }

      void navigator.clipboard
        .readText()
        .then((text) => {
          if (
            text.length === 0 ||
            textareaRef.current !== textarea ||
            textarea.value !== beforeValue
          ) {
            return;
          }

          const nextValue =
            beforeValue.slice(0, selectionStart) +
            text +
            beforeValue.slice(selectionEnd);
          handleDraftChange(nextValue);
          requestAnimationFrame(() => {
            const cursor = selectionStart + text.length;
            textarea.setSelectionRange(cursor, cursor);
          });
        })
        .catch(() => undefined);
    }, 0);
  }

  async function handlePaste(event: ClipboardEvent<HTMLTextAreaElement>) {
    const items = filterSupportedAttachmentTransferItems(
      extractAttachmentTransferItems(event.clipboardData),
    );
    if (items.length === 0) {
      return;
    }

    handledPasteAtRef.current = Date.now();
    event.preventDefault();
    await attachTransferItems(items);
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
      {queuedPrompts.length > 0 ? (
        <div className="mb-2 rounded-xl border border-border/70 bg-card/70 px-3 py-2 text-xs text-muted-foreground shadow-sm">
          <div className="font-medium text-foreground">
            Messages queued to send after this turn
          </div>
          <ul className="mt-1 space-y-1">
            {queuedPrompts.map((queuedPrompt, index) => (
              <li key={`${index}:${queuedPrompt.value}`} className="flex gap-2">
                <span aria-hidden className="text-muted-foreground">
                  -&gt;
                </span>
                <span className="min-w-0 whitespace-pre-wrap break-words">
                  {queuedPrompt.value}
                </span>
              </li>
            ))}
          </ul>
        </div>
      ) : null}
      <Card
        className={cn(
          "relative gap-0 rounded-2xl border border-foreground/5 bg-background/50 p-2 transition-colors transition-shadow ring-0",
          isPlanningMode &&
            "border-[color:var(--accent)] ring-5 ring-[color:color-mix(in_oklab,var(--accent)_14%,transparent)] border-dashed",
          isUltraMode && "cg-ultra-shine border-transparent",
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
                ref={commandOverlayRef}
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
                commandMatch &&
                  "text-transparent caret-[color:var(--foreground)]",
              )}
              placeholder={
                isWorking
                  ? "Queue a follow-up…"
                  : isUltraMode
                    ? "Describe the job — Ultra fans out parallel agents"
                    : placeholder
              }
              value={promptDraft}
              onChange={(event) => handleDraftChange(event.target.value)}
              onPaste={handlePaste}
              onScroll={(event) => {
                if (commandOverlayRef.current != null) {
                  commandOverlayRef.current.scrollTop =
                    event.currentTarget.scrollTop;
                }
              }}
              onKeyDown={(event) => {
                scheduleClipboardTextPasteFallback(event);
                if (
                  shouldHandlePlanningModeShortcut(event, isControlDisabled)
                ) {
                  handlePlanningModeShortcut(event);
                  return;
                }
                // The command menu consumes Enter/Tab/arrows while open, so a
                // command is completed rather than sent.
                if (commandAutocomplete.handleKeyDown(event)) {
                  return;
                }
                if (handleHistoryNavigation(event)) {
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
                const currentDraft = event.currentTarget.value;
                if (canSubmitDraft(currentDraft)) {
                  handleSubmit(currentDraft);
                }
              }}
              disabled={isTextareaDisabled}
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
              onClick={handleFastToggle}
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
              onClick={() => setUltraMode(!isUltraMode)}
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
            onClick={handlePrimaryAction}
            disabled={isWorking ? false : isSubmitDisabled}
          >
            {isWorking && isSubmitDisabled ? <SquareIcon /> : <ArrowUpIcon />}
          </Button>
        </CardFooter>
      </Card>
    </div>
  );
}

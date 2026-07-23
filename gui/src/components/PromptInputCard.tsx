import { useEffect, useRef, useState, type KeyboardEvent } from "react";

import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/Card";
import { Textarea } from "@/components/ui/Textarea";
import { CommandAutocomplete } from "@/components/CommandAutocomplete";
import { AttachmentTray } from "@/components/attachments/AttachmentTray";
import { DropOverlay } from "@/components/attachments/DropOverlay";
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
import { updateWorkspaceFastMode } from "@/app/sessionClientActions";
import { savePastedImage } from "@/services/desktop/client";
import { cn } from "@/utils/cn";
import {
  getPromptHistoryNavigationResult,
  type PromptHistoryCursor,
} from "./promptHistoryNavigation";
import {
  formatPlanningThinkingLabel,
} from "@/utils/reasoning";
import { PromptControlBar } from "./PromptControlBar";
import type { PromptInputCardProps } from "./types/prompt";

const EMPTY_PROMPT_HISTORY: string[] = [];

function isCaretOnFirstLine(textarea: HTMLTextAreaElement) {
  return !textarea.value.slice(0, textarea.selectionStart).includes("\n");
}

function isCaretOnLastLine(textarea: HTMLTextAreaElement) {
  return !textarea.value.slice(textarea.selectionEnd).includes("\n");
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
  const { attachments, addAttachments, removeAttachment, replaceAttachments } =
    useAttachments(binding);
  const { isActive: isDropActive } = useDropZone(dropZoneRef, (paths) => {
    const accepted = paths
      .map((path) => classifyPath(path))
      .filter((item): item is NonNullable<typeof item> => item != null);
    addAttachments(accepted);
  });
  const isControlDisabled =
    isSendingPrompt || isRequestActive || !canCompose || isInputDisabled;
  // Keep the composer editable while a request streams so the user can draft
  // and queue the next message. While streaming, a non-empty draft turns the
  // primary button back into Send; an empty draft keeps it as Stop.
  const isTextareaDisabled = isSendingPrompt || !canCompose || isInputDisabled;
  const isWorking = isRequestActive;
  const isQueueSubmit = isWorking;
  const isSubmitDisabled =
    !canCompose ||
    isInputDisabled ||
    (!isQueueSubmit && isSendingPrompt) ||
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

  const [fastOverride, setFastOverride] = useState<{
    source: boolean;
    value: boolean;
  } | null>(null);
  const [historyCursor, setHistoryCursor] =
    useState<PromptHistoryCursor>(null);
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

  // Whether /fast actually changes harness behavior. The harness only applies
  // the priority service tier on the codex provider (the `responses` kind); it
  // is a no-op everywhere else. The runtime reports this authoritatively via
  // `fastApplies`, so the toggle stays active only when it's true.
  const fastApplies = promptSettings?.fastApplies ?? false;
  const authoritativeFastEnabled = promptSettings?.fastEnabled ?? false;
  const fastEnabled =
    fastOverride?.source === authoritativeFastEnabled
      ? fastOverride.value
      : authoritativeFastEnabled;

  function handleFastToggle() {
    if (!fastApplies) return;
    const next = !fastEnabled;
    setFastOverride({ source: authoritativeFastEnabled, value: next });
    void updateWorkspaceFastMode(workspacePath ?? null, next).then(() => {
      setFastOverride(null);
    });
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
    enabled: canCompose && !isInputDisabled,
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

  function handleSubmit() {
    if (isSubmitDisabled) {
      return;
    }

    resetHistoryNavigation();
    void submitPrompt();
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

  function handleHistoryNavigation(
    event: KeyboardEvent<HTMLTextAreaElement>,
  ) {
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
    if (!isSubmitDisabled) {
      handleSubmit();
      return;
    }

    if (isWorking) {
      void stopPrompt();
    }
  }

  function handlePlanningModeToggle() {
    setPlanningMode(!isPlanningMode);
  }

  // Cmd/Ctrl+V of an image: persist the clipboard bytes to a temp file and add
  // it through the same attachment pipeline as a drag-dropped file.
  async function handlePaste(event: React.ClipboardEvent<HTMLTextAreaElement>) {
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
                if (!isSubmitDisabled) {
                  handleSubmit();
                }
              }}
              disabled={isTextareaDisabled}
              rows={3}
            />
          </div>
        </CardContent>
        <PromptControlBar
          fastApplies={fastApplies}
          fastEnabled={fastEnabled}
          hasAvailableModels={hasAvailableModels}
          isControlDisabled={isControlDisabled}
          isModelMenuOpen={isModelMenuOpen}
          isPlanningMode={isPlanningMode}
          isSubmitDisabled={isSubmitDisabled}
          isUltraMode={isUltraMode}
          isWorking={isWorking}
          modelSearchQuery={modelSearchQuery}
          planningThinkingLabel={planningThinkingLabel}
          selectedModelLabel={selectedModelLabel}
          selectedModelValue={selectedModelValue}
          selectedReasoning={selectedReasoning}
          selectedReasoningEfforts={selectedReasoningEfforts}
          visibleModels={visibleModels}
          onFastToggle={handleFastToggle}
          onModelChange={handleModelChange}
          onModelMenuOpenChange={handleModelMenuOpenChange}
          onPlanningModeToggle={handlePlanningModeToggle}
          onPrimaryAction={handlePrimaryAction}
          onReasoningChange={handleReasoningChange}
          onSearchQueryChange={setModelSearchQuery}
          onUltraModeToggle={() => setUltraMode(!isUltraMode)}
        />
      </Card>
    </div>
  );
}

import { useCallback, useRef, useState } from "react";

import { useSettingsNavigation } from "@/app/settingsNavigationContext";
import { sessionStore } from "@/app/sessionStore";
import * as desktopClient from "@/services/desktop/client";
import type {
  ChatBinding,
  CommandDescriptor,
  CommandRunResult,
} from "@/services/desktop/types/contracts";

import { usePrompt } from "./usePrompt";
import { useSessionActions } from "./useSession";

/** Commands that need free-form arguments before they can run. */
const ARG_COMMANDS = new Set([
  "rename",
  "workspace-query",
  "workspace-search",
  "workflow",
  "goal",
  "loop",
  "bash",
  "reasoning-effort",
]);

interface ParsedCommand {
  name: string;
  args: string[];
}

interface UseCommandRouterOptions {
  onCommandResult?: (result: CommandRunResult) => void;
}

export function parseSlashCommand(draft: string): ParsedCommand | null {
  const match = /^\/([\w-]+)(?:\s+([\s\S]*))?$/.exec(draft.trim());
  if (match == null) {
    return null;
  }
  const name = match[1];
  const rest = match[2]?.trim() ?? "";
  return {
    name,
    args: rest.length > 0 ? (name === "bash" ? [rest] : rest.split(/\s+/)) : [],
  };
}

/**
 * Detects a known slash command that begins a *continuation* line of the draft
 * (after optional leading spaces/tabs) and returns its name, or null. The whole
 * draft is only routed as a command when its entire trimmed body is one command
 * (see `parseSlashCommand`), so a command starting a later line is otherwise sent
 * silently as prose. The match is anchored to the start of each line, so mid-line
 * `/tokens` in paths, URLs, or quoted commands never false-positive. The first
 * line is skipped because it is already handled by `parseSlashCommand`.
 */
export function findLineLeadingCommand(draft: string): string | null {
  const lines = draft.split("\n");
  for (let index = 1; index < lines.length; index += 1) {
    const match = /^[ \t]*\/([\w-]+)(?:\s|$)/.exec(lines[index]);
    if (match != null && ARG_COMMANDS.has(match[1])) {
      return match[1];
    }
  }
  return null;
}

/**
 * Routes accepted slash-commands to GUI actions, backend execution, or, when a
 * command needs arguments, completes it into the draft so the user can finish
 * and submit. Surfaces informational results through a dialog.
 */
export function useCommandRouter(
  binding?: ChatBinding | null,
  options: UseCommandRouterOptions = {},
): {
  workspacePath: string | null;
  handleCommandSelect: (command: CommandDescriptor) => void;
  /** Returns true if the draft was dispatched as a command (skip send). */
  trySubmitAsCommand: (draft: string) => boolean;
  commandResult: CommandRunResult | null;
  dismissCommandResult: () => void;
  /**
   * Set when the current dialog is the "stray command on a later line" warning;
   * calling it sends the draft unchanged as an ordinary prompt. Null otherwise.
   */
  sendDraftAsText: (() => void) | null;
} {
  const { isPlanningMode, setPlanningMode, setPromptDraft, submitPrompt } =
    usePrompt(binding);
  const { startNewChat, archiveConversation } = useSessionActions();
  const { openProviderSettings, openMcpSettings } = useSettingsNavigation();
  const workspacePath = binding?.workspacePath ?? null;
  const conversationId = binding?.conversationId ?? null;
  const { onCommandResult } = options;
  const [commandResult, setCommandResult] = useState<CommandRunResult | null>(
    null,
  );
  // True while `commandResult` is the stray-command warning, so the composer
  // can offer a "send as text" action alongside the default "return to editing".
  const [strayCommandWarning, setStrayCommandWarning] = useState(false);
  // Guards the atomic `/goal` start against duplicate execution from repeated
  // submit events / retries: holds the in-flight `conversation:objective` key.
  const inFlightGoalRef = useRef<string | null>(null);
  const publishCommandResult = useCallback(
    (result: CommandRunResult) => {
      if (result.payload?.kind === "workflowDraft") {
        setCommandResult(result);
        return;
      }
      if (onCommandResult != null) {
        onCommandResult(result);
        return;
      }
      setCommandResult(result);
    },
    [onCommandResult],
  );

  const runBackend = useCallback(
    (name: string, args: string[]) => {
      void desktopClient
        .runSlashCommand({ name, args, workspacePath, conversationId })
        .then((result) => {
          if (result.snapshot != null) {
            sessionStore.getState().applySessionSnapshot(result.snapshot);
          }
          if (
            result.body != null ||
            result.savedPath != null ||
            result.payload != null
          ) {
            publishCommandResult(result);
          }
        })
        .catch((error: unknown) => {
          const result = {
            title: "Command failed",
            body: error instanceof Error ? error.message : String(error),
            snapshot: null,
            savedPath: null,
            resultKind: "text",
            payload: null,
          } satisfies CommandRunResult;
          publishCommandResult(result);
        });
    },
    [conversationId, publishCommandResult, workspacePath],
  );

  // Runs a command with already-parsed arguments. Returns true when handled.
  const dispatch = useCallback(
    (name: string, args: string[]): boolean => {
      switch (name) {
        case "goal": {
          const objective = args.join(" ").trim();
          // `/goal` (show current) and `/goal clear` are display/reset only;
          // they never start a turn, so leave them on the save-only path.
          if (objective.length === 0 || objective.toLowerCase() === "clear") {
            runBackend(name, args);
            return true;
          }
          // Without a persisted conversation we cannot start a turn, so fall
          // back to saving the goal only (the backend confirmation for that
          // path does not imply work has begun).
          if (workspacePath == null || conversationId == null) {
            runBackend(name, args);
            return true;
          }
          // Atomic: persist the goal, then start exactly one turn for it.
          // The in-flight guard drops duplicate submit events for the same goal.
          const guardKey = `${conversationId}:${objective}`;
          if (inFlightGoalRef.current === guardKey) {
            return true;
          }
          inFlightGoalRef.current = guardKey;
          void (async () => {
            try {
              const persisted = await desktopClient.runSlashCommand({
                name: "goal",
                args,
                workspacePath,
                conversationId,
              });
              if (persisted.snapshot != null) {
                sessionStore.getState().applySessionSnapshot(persisted.snapshot);
              }
              const snapshot = await desktopClient.sendPrompt({
                agentId: isPlanningMode ? "muse" : "forge",
                conversationId,
                prompt: objective,
                workspacePath,
              });
              sessionStore.getState().applySessionSnapshot(snapshot);
            } catch {
              // Leave no stale guard so the user can retry after a failure.
            } finally {
              inFlightGoalRef.current = null;
            }
          })();
          return true;
        }
        case "plan":
        case "muse":
          setPlanningMode(true);
          return true;
        case "act":
        case "forge":
          setPlanningMode(false);
          return true;
        case "new":
          void startNewChat(workspacePath ?? undefined);
          return true;
        case "login":
        case "provider":
        case "logout":
          openProviderSettings();
          return true;
        case "mcp-settings":
          openMcpSettings();
          return true;
        case "delete":
          if (workspacePath != null && conversationId != null) {
            void archiveConversation(workspacePath, conversationId);
          }
          return true;
        case "compact":
          if (binding != null) {
            void desktopClient
              .compactConversation(binding)
              .then((snapshot) => {
                sessionStore.getState().applySessionSnapshot(snapshot);
              })
              .catch(() => null);
          }
          return true;
        default:
          if (name === "mcp" && args.length === 0) {
            openMcpSettings();
            return true;
          }
          if (name.startsWith("agent-")) {
            runBackend(name, args);
            return true;
          }
          runBackend(name, args);
          return true;
      }
    },
    [
      archiveConversation,
      binding,
      conversationId,
      isPlanningMode,
      openProviderSettings,
      openMcpSettings,
      runBackend,
      setPlanningMode,
      startNewChat,
      workspacePath,
    ],
  );

  const handleCommandSelect = useCallback(
    (command: CommandDescriptor) => {
      // Commands that need arguments are completed into the draft so the user
      // can type the arguments, then submit.
      if (ARG_COMMANDS.has(command.name)) {
        setPromptDraft(`/${command.name} `);
        return;
      }
      if (command.executionKind === "unavailable") {
        setPromptDraft(`/${command.name} `);
        return;
      }
      if (command.executionKind === "terminalAssisted") {
        publishCommandResult({
          title: `/${command.name}`,
          body:
            command.argumentHint == null
              ? "Open a terminal pane to run this workflow."
              : `Open a terminal pane to run this workflow: /${command.name} ${command.argumentHint}`,
          snapshot: null,
          savedPath: null,
          resultKind: "text",
          payload: null,
        });
        setPromptDraft("");
        return;
      }
      if (dispatch(command.name, [])) {
        setPromptDraft("");
        return;
      }
      // Not wired yet: complete into the draft as a typing aid.
      setPromptDraft(`/${command.name} `);
    },
    [dispatch, publishCommandResult, setPromptDraft],
  );

  const dismissCommandResult = useCallback(() => {
    setCommandResult(null);
    setStrayCommandWarning(false);
  }, []);

  const confirmSendDraftAsText = useCallback(() => {
    setCommandResult(null);
    setStrayCommandWarning(false);
    void submitPrompt();
  }, [submitPrompt]);

  const trySubmitAsCommand = useCallback(
    (draft: string): boolean => {
      const parsed = parseSlashCommand(draft);
      if (parsed == null) {
        // A known command that starts a *later* line would otherwise be sent
        // silently as prose. Warn and let the user decide before that happens.
        const strayCommand = findLineLeadingCommand(draft);
        if (strayCommand != null) {
          setStrayCommandWarning(true);
          setCommandResult({
            title: "Did you mean to run a command?",
            body: `"/${strayCommand}" looks like a command, but it is not on the first line, so the whole message will be sent as ordinary text and the command will not run.\n\nReturn to editing to move it to its own message, or send this text unchanged.`,
            snapshot: null,
            savedPath: null,
            resultKind: "text",
            payload: null,
          });
          return true;
        }
        return false;
      }
      const handled = dispatch(parsed.name, parsed.args);
      if (handled) {
        setPromptDraft("");
      }
      return handled;
    },
    [dispatch, setPromptDraft],
  );

  return {
    workspacePath,
    handleCommandSelect,
    trySubmitAsCommand,
    commandResult,
    dismissCommandResult,
    sendDraftAsText: strayCommandWarning ? confirmSendDraftAsText : null,
  };
}

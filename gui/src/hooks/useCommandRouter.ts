import { useCallback, useEffect, useState } from "react";

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

const LOCAL_COMMANDS = new Set([
  "act",
  "compact",
  "delete",
  "forge",
  "login",
  "mcp-settings",
  "muse",
  "new",
  "plan",
  "provider",
  "logout",
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
} {
  const { setPlanningMode, setPromptDraft } = usePrompt(binding);
  const { startNewChat, archiveConversation } = useSessionActions();
  const { openProviderSettings, openMcpSettings } = useSettingsNavigation();
  const workspacePath = binding?.workspacePath ?? null;
  const conversationId = binding?.conversationId ?? null;
  const { onCommandResult } = options;
  const [commands, setCommands] = useState<CommandDescriptor[]>([]);
  const [commandsLoaded, setCommandsLoaded] = useState(false);
  const [commandResult, setCommandResult] = useState<CommandRunResult | null>(
    null,
  );

  useEffect(() => {
    let cancelled = false;
    desktopClient
      .listCommands(workspacePath)
      .then((result) => {
        if (!cancelled) {
          setCommands(result);
          setCommandsLoaded(true);
        }
      })
      .catch(() => {
        if (!cancelled) {
          setCommands([]);
          setCommandsLoaded(false);
        }
      });
    return () => {
      cancelled = true;
    };
  }, [workspacePath]);

  const resolveCommand = useCallback(
    (name: string): CommandDescriptor | null => {
      const needle = name.toLowerCase();
      return (
        commands.find(
          (candidate) =>
            candidate.name.toLowerCase() === needle ||
            candidate.aliases.some((alias) => alias.toLowerCase() === needle),
        ) ?? null
      );
    },
    [commands],
  );

  const canonicalCommandName = useCallback(
    (name: string): string => resolveCommand(name)?.name ?? name,
    [resolveCommand],
  );

  const isRunnableSlashCommand = useCallback(
    (name: string): boolean => {
      const canonicalName = canonicalCommandName(name);
      if (LOCAL_COMMANDS.has(canonicalName) || canonicalName.startsWith("agent-")) {
        return true;
      }
      return commandsLoaded && resolveCommand(name) != null;
    },
    [canonicalCommandName, commandsLoaded, resolveCommand],
  );

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
          const message = error instanceof Error ? error.message : String(error);
          if (message.includes("/api/run_slash_command") && message.includes("404")) {
            setCommands([]);
            setCommandsLoaded(false);
          }
          const result = {
            title: "Command failed",
            body: message,
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

  const trySubmitAsCommand = useCallback(
    (draft: string): boolean => {
      const parsed = parseSlashCommand(draft);
      if (parsed == null) {
        return false;
      }
      if (!isRunnableSlashCommand(parsed.name)) {
        return false;
      }
      const handled = dispatch(canonicalCommandName(parsed.name), parsed.args);
      if (handled) {
        setPromptDraft("");
      }
      return handled;
    },
    [canonicalCommandName, dispatch, isRunnableSlashCommand, setPromptDraft],
  );

  return {
    workspacePath,
    handleCommandSelect,
    trySubmitAsCommand,
    commandResult,
    dismissCommandResult: () => setCommandResult(null),
  };
}

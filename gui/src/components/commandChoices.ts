import type { CommandDescriptor } from "@/services/desktop/types/contracts";

/**
 * `/ultracode` is a GUI-only toggle (it flips the same per-prompt ultra mode the
 * Ultra footer button uses) rather than a backend slash command, so we surface a
 * synthetic descriptor for it in autocomplete.
 */
export const ULTRACODE_COMMAND: CommandDescriptor = {
  name: "ultracode",
  usage: "Toggle ultracode (multi-agent) mode for your next prompt.",
  aliases: [],
  kind: "builtin",
  value: null,
  isAgentSwitch: false,
  executionKind: "runnable",
  requiresWorkspace: false,
  requiresConversation: false,
  argumentHint: "<on|off>",
  resultKind: "text",
};

function ultracodeChoice(on: boolean): CommandDescriptor {
  return {
    ...ULTRACODE_COMMAND,
    name: on ? "ultracode on" : "ultracode off",
    usage: on ? "Enable ultracode for your next prompt." : "Disable ultracode.",
    argumentHint: null,
  };
}

export interface CommandChoiceContext {
  ultracodeEnabled: boolean;
}

/**
 * Expands a choice-command into its selectable rows, or returns null when `name`
 * is not a choice-command. The opposite of the current state is listed first so
 * the default highlight (index 0) flips the mode when the user presses Enter.
 */
export function getCommandChoices(
  name: string,
  ctx: CommandChoiceContext,
): CommandDescriptor[] | null {
  if (name === ULTRACODE_COMMAND.name) {
    const on = ultracodeChoice(true);
    const off = ultracodeChoice(false);
    return ctx.ultracodeEnabled ? [off, on] : [on, off];
  }
  return null;
}

/**
 * Parses a choice descriptor name such as `"ultracode on"` into its command name
 * and argument. Returns null for plain (single-token) command names.
 */
export function parseChoiceCommand(
  name: string,
): { name: string; arg: string } | null {
  const match = /^(\S+)\s+(\S+)$/.exec(name);
  if (match == null) {
    return null;
  }
  return { name: match[1], arg: match[2] };
}

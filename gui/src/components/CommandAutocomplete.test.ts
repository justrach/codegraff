import { describe, expect, test } from "bun:test";

import type { CommandDescriptor } from "@/services/desktop/types/contracts";
import { commandMatchesExactQuery } from "@/hooks/useCommandAutocomplete";
import { getCommandExecutionLabel } from "./commandAutocompleteUtils";

function commandFixture(
  executionKind: CommandDescriptor["executionKind"],
): CommandDescriptor {
  return {
    aliases: [],
    argumentHint: null,
    executionKind,
    isAgentSwitch: false,
    kind: "builtin",
    name: "logs",
    requiresConversation: false,
    requiresWorkspace: false,
    resultKind: "text",
    usage: "Show logs",
    value: null,
  };
}

describe("getCommandExecutionLabel", () => {
  test("maps runnable command state", () => {
    const setup = commandFixture("runnable");
    const actual = getCommandExecutionLabel(setup);
    const expected = "Run";
    expect(actual).toBe(expected);
  });

  test("maps terminal-assisted command state", () => {
    const setup = commandFixture("terminalAssisted");
    const actual = getCommandExecutionLabel(setup);
    const expected = "Terminal";
    expect(actual).toBe(expected);
  });
});

describe("commandMatchesExactQuery", () => {
  test("matches an exact command name", () => {
    const setup = commandFixture("runnable");
    const actual = commandMatchesExactQuery(setup, "logs");
    const expected = true;
    expect(actual).toBe(expected);
  });

  test("matches an exact command alias", () => {
    const setup = { ...commandFixture("runnable"), aliases: ["plan"] };
    const actual = commandMatchesExactQuery(setup, "plan");
    const expected = true;
    expect(actual).toBe(expected);
  });

  test("does not match a partial command alias", () => {
    const setup = { ...commandFixture("runnable"), aliases: ["plan"] };
    const actual = commandMatchesExactQuery(setup, "pla");
    const expected = false;
    expect(actual).toBe(expected);
  });
});

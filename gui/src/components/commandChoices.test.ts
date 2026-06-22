import { describe, expect, test } from "bun:test";

import {
  ULTRACODE_COMMAND,
  getCommandChoices,
  parseChoiceCommand,
} from "./commandChoices";

describe("getCommandChoices", () => {
  test("ultracode lists `on` first when currently off", () => {
    const choices = getCommandChoices("ultracode", { ultracodeEnabled: false });
    expect(choices?.map((c) => c.name)).toEqual([
      "ultracode on",
      "ultracode off",
    ]);
  });

  test("ultracode lists `off` first when currently on", () => {
    const choices = getCommandChoices("ultracode", { ultracodeEnabled: true });
    expect(choices?.map((c) => c.name)).toEqual([
      "ultracode off",
      "ultracode on",
    ]);
  });

  test("returns null for non-choice commands", () => {
    expect(getCommandChoices("help", { ultracodeEnabled: false })).toBeNull();
  });
});

describe("parseChoiceCommand", () => {
  test("splits a choice descriptor name into command + arg", () => {
    expect(parseChoiceCommand("ultracode on")).toEqual({
      name: "ultracode",
      arg: "on",
    });
  });

  test("returns null for a plain command name", () => {
    expect(parseChoiceCommand("ultracode")).toBeNull();
  });
});

describe("ULTRACODE_COMMAND", () => {
  test("is a discoverable builtin descriptor", () => {
    expect(ULTRACODE_COMMAND.name).toBe("ultracode");
    expect(ULTRACODE_COMMAND.kind).toBe("builtin");
  });
});

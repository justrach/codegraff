import { describe, expect, test } from "bun:test";

import { findLineLeadingCommand, parseSlashCommand } from "./useCommandRouter";

describe("parseSlashCommand", () => {
  test("returns null for a plain prompt with no slash", () => {
    expect(parseSlashCommand("hello world")).toBeNull();
    expect(parseSlashCommand("")).toBeNull();
  });

  test("parses a bare command with no args", () => {
    const parsed = parseSlashCommand("/help");
    expect(parsed).not.toBeNull();
    expect(parsed?.name).toBe("help");
    expect(parsed?.args).toEqual([]);
  });

  test("bash preserves the full raw argument string as a single arg", () => {
    // Regression guard for PR #38: /bash must NOT split on whitespace, or
    // quoted/compound commands (`echo "a b"`, `sh -c "x && y"`) get mangled.
    const parsed = parseSlashCommand('/bash echo "hello world"');
    expect(parsed?.name).toBe("bash");
    expect(parsed?.args).toEqual(['echo "hello world"']);
  });

  test("bash preserves shell metacharacters and pipes inside the arg", () => {
    const parsed = parseSlashCommand("/bash ls -la | grep src");
    expect(parsed?.name).toBe("bash");
    expect(parsed?.args).toEqual(["ls -la | grep src"]);
  });

  test("non-bash commands still split args on whitespace", () => {
    const parsed = parseSlashCommand("/rename My Cool Chat");
    expect(parsed?.name).toBe("rename");
    expect(parsed?.args).toEqual(["My", "Cool", "Chat"]);
  });

  test("bash with no args yields an empty args array", () => {
    const parsed = parseSlashCommand("/bash");
    expect(parsed?.name).toBe("bash");
    expect(parsed?.args).toEqual([]);
  });

  test("bash preserves multiline command bodies", () => {
    const parsed = parseSlashCommand("/bash echo line1\necho line2");
    expect(parsed?.name).toBe("bash");
    expect(parsed?.args).toEqual(["echo line1\necho line2"]);
  });
});

describe("findLineLeadingCommand", () => {
  test("detects a known command that begins a non-first line", () => {
    expect(findLineLeadingCommand("context\n/goal investigate")).toBe("goal");
  });

  test("matches a command after leading spaces on a later line", () => {
    expect(findLineLeadingCommand("do the thing\n   /loop keep going")).toBe(
      "loop",
    );
  });

  test("ignores the first line (already handled by parseSlashCommand)", () => {
    expect(findLineLeadingCommand("/goal do it\nmore prose")).toBeNull();
  });

  test("returns null for a plain multi-line prompt", () => {
    expect(findLineLeadingCommand("line one\nline two")).toBeNull();
    expect(findLineLeadingCommand("just one line /goal here")).toBeNull();
  });

  test("does not match a command embedded mid-line", () => {
    expect(findLineLeadingCommand("first\nbar /goal baz")).toBeNull();
  });

  test("does not match an unknown command on a later line", () => {
    expect(findLineLeadingCommand("first\n/unknowncmd please")).toBeNull();
  });

  test("does not false-positive on paths, URLs, or quoted commands", () => {
    expect(findLineLeadingCommand("see\n/usr/local/bin/tool")).toBeNull();
    expect(findLineLeadingCommand("docs\nhttps://example.com/goal")).toBeNull();
    expect(findLineLeadingCommand('note\n"/goal x" was run earlier')).toBeNull();
  });

  test("does not match a longer token that only starts with a command name", () => {
    expect(findLineLeadingCommand("first\n/goals of the project")).toBeNull();
  });
});

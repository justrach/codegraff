import { describe, expect, test } from "bun:test";

import { parseSlashCommand } from "./useCommandRouter";

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

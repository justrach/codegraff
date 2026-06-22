import { describe, expect, test } from "bun:test";

import {
  classifyUnknownToolName,
  detectContentFormat,
  resolvePresentation,
} from "./classifyActivityResult";

describe("classifyUnknownToolName", () => {
  test("maps webfetch-like names to web", () => {
    expect(classifyUnknownToolName("webfetch")).toBe("web");
    expect(classifyUnknownToolName("web_fetch")).toBe("web");
    expect(classifyUnknownToolName("http_get")).toBe("web");
  });

  test("maps github-like names to github", () => {
    expect(classifyUnknownToolName("github_create_pr")).toBe("github");
    expect(classifyUnknownToolName("gh_issue")).toBe("github");
  });

  test("falls back to generic", () => {
    expect(classifyUnknownToolName("do_thing")).toBe("generic");
  });
});

describe("detectContentFormat", () => {
  test("shell output is terminal", () => {
    const actual = detectContentFormat({
      detailKind: "shell",
      name: "shell",
      isShellOutput: true,
      text: "ok",
    });
    expect(actual.format).toBe("terminal");
  });

  test("unknown web tool is prose", () => {
    const actual = detectContentFormat({
      detailKind: "unknown",
      name: "webfetch",
      isShellOutput: false,
      text: "Some fetched page body that is plain text.",
    });
    expect(actual.format).toBe("prose");
  });

  test("JSON output is code with json language", () => {
    const actual = detectContentFormat({
      detailKind: "unknown",
      name: "lookup",
      isShellOutput: false,
      text: '{"a": 1, "b": [2, 3]}',
    });
    expect(actual.format).toBe("code");
    expect(actual.language).toBe("json");
  });

  test("code-dense output is code", () => {
    const actual = detectContentFormat({
      detailKind: "unknown",
      name: "gen",
      isShellOutput: false,
      text: "const x = 1;\nfunction f() {\n  return x;\n}",
    });
    expect(actual.format).toBe("code");
  });

  test("plain prose stays prose", () => {
    const actual = detectContentFormat({
      detailKind: "unknown",
      name: "summarize",
      isShellOutput: false,
      text: "This is a normal sentence describing the result.",
    });
    expect(actual.format).toBe("prose");
  });
});

describe("resolvePresentation", () => {
  test("short non-error prose renders inline", () => {
    expect(
      resolvePresentation({ text: "Done.", tone: "default", format: "prose" }),
    ).toBe("inline");
  });

  test("errors always get a card", () => {
    expect(
      resolvePresentation({ text: "boom", tone: "error", format: "prose" }),
    ).toBe("card");
  });

  test("terminal and code always get a card", () => {
    expect(
      resolvePresentation({ text: "x", tone: "default", format: "terminal" }),
    ).toBe("card");
    expect(
      resolvePresentation({ text: "x", tone: "default", format: "code" }),
    ).toBe("card");
  });

  test("long prose gets a card", () => {
    const longText = Array.from({ length: 8 }, () => "line").join("\n");
    expect(
      resolvePresentation({ text: longText, tone: "default", format: "prose" }),
    ).toBe("card");
  });
});

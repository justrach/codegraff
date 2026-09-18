import { test, expect } from "bun:test";
import { guiSkillRows, parseComposerToken, selectedGuiSkills, withoutGuiSkillContext } from "./gui-skills";
import { prepareGuiPrompt } from "./gui-skill-context";
test("at and dollar discover GUI skills without stealing file or slash completion", () => {
  expect(parseComposerToken("Try $th")?.kind).toBe("skill");
  expect(parseComposerToken("Try @th")?.kind).toBe("at");
  expect(parseComposerToken("@src/main.zig")?.query).toBe("src/main.zig");
  expect(parseComposerToken("/effort")?.kind).toBe("slash");
  expect(guiSkillRows("theme")[0].name).toBe("$theme");
  expect(guiSkillRows("mcp")[0].name).toBe("$mcp");
});
test("only explicit, unquoted GUI skill mentions activate context", () => {
  expect(selectedGuiSkills("$theme make it green @theme")).toHaveLength(1);
  for (const text of ["`$theme`", "```\n@theme\n```", "email@theme", "@$theme", "$theme-old", "@[theme]", "@theme/file", "regular prompt"]) expect(selectedGuiSkills(text)).toEqual([]);
});
test("GUI skill instructions arrive through ACP while display text and other blocks survive", async () => {
  const original = { sessionId: "fixture", prompt: [{ type: "text", text: "$theme make a garden palette" }, { type: "image", data: "fixture" }] };
  const prepared = await prepareGuiPrompt(original);
  const blocks = prepared?.prompt as typeof original.prompt;
  expect(blocks[0].text).toContain("GUI skill: theme");
  expect(blocks[0].text).toContain("Theme directory for this desktop:");
  expect(withoutGuiSkillContext(blocks[0].text!)).toBe(original.prompt[0].text!);
  expect(blocks[1]).toEqual(original.prompt[1]);
  expect(original.prompt[0].text).toBe("$theme make a garden palette");
});
test("ordinary prompts and file attachments do not load GUI skills", async () => {
  const original = { prompt: [{ type: "text", text: "Read the project" }, { type: "resource_link", name: "$theme", uri: "file:///fixture" }] };
  expect(await prepareGuiPrompt(original)).toBe(original);
});
test("MCP GUI skill injects config paths without the theme directory", async () => {
  const original = { prompt: [{ type: "text", text: "$mcp add a filesystem server" }] };
  const prepared = await prepareGuiPrompt(original);
  const text = (prepared?.prompt as { text: string }[])[0].text;
  expect(text).toContain("GUI skill: mcp");
  expect(text).toContain("User MCP config for this desktop:");
  expect(text).toContain("Workspace MCP config for this desktop:");
  expect(text).not.toContain("Theme directory for this desktop:");
  expect(withoutGuiSkillContext(text)).toBe(original.prompt[0].text);
});

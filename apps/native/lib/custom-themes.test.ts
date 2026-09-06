import { test, expect } from "bun:test";
import { mkdtemp, rm, writeFile, symlink, readFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { parseTheme, contrast, themeWarnings } from "./custom-themes";
import { listThemes, saveTheme } from "./theme-files";
export const sampleTheme = { version: 1, id: "test-garden", name: "Test Garden", base: "dark", colors: { page: "#15201c", surface: "#1c2a23", ink: "#f1f7ee", "ink-2": "#c1d4c3", "ink-3": "#a3baa6", accent: "#a4d98c", "accent-ink": "#b5e79e", "accent-tint": "#2c422c" }, font: "system", corners: 10 };
test("portable theme validates and keeps readable text", () => {
  expect(parseTheme(sampleTheme).id).toBe("test-garden");
  expect(themeWarnings(parseTheme(sampleTheme))).toEqual([]);
  expect(contrast("#ffffff", "#000000")).toBe(21);
});
test("theme schema rejects executable values, unknown tokens and invalid identifiers", () => {
  for (const patch of [{ id: "../outside" }, { version: 2 }, { base: "unknown" }, { font: ["system"] }, { corners: -1 }, { css: "body{}" }, { colors: { ...sampleTheme.colors, page: "url(https://example.com)" } }, { colors: { ...sampleTheme.colors, position: "#ffffff" } }, { colors: {} }]) expect(() => parseTheme({ ...sampleTheme, ...patch })).toThrow();
});
test("contrast warnings identify unreadable secondary text", () => {
  expect(themeWarnings(parseTheme({ ...sampleTheme, colors: { ...sampleTheme.colors, "ink-3": "#15201c" } }))).toContain("ink-3 on page has low text contrast.");
});
test("theme import is atomic, lists valid files, and preserves duplicate ids", async () => {
  const directory = await mkdtemp(path.join(os.tmpdir(), "theme-files-"));
  try {
    await saveTheme(sampleTheme, directory);
    await expect(saveTheme({ ...sampleTheme, name: "Overwrite" }, directory)).rejects.toThrow();
    await writeFile(path.join(directory, "broken.json"), "{");
    await writeFile(path.join(directory, "huge.json"), " ".repeat(20_000));
    await symlink(path.join(directory, "test-garden.json"), path.join(directory, "link.json"));
    const result = await listThemes(directory);
    expect(result.themes.map(theme => theme.name)).toEqual(["Test Garden"]);
    expect(result.issues).toHaveLength(3);
    expect(JSON.parse(await readFile(path.join(directory, "test-garden.json"), "utf8")).name).toBe("Test Garden");
  } finally { await rm(directory, { recursive: true, force: true }); }
});

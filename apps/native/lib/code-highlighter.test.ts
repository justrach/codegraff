import { test, expect } from "bun:test";
import type { Highlighter } from "shiki";
import { createCodeHighlighter, CODE_HIGHLIGHT_LIMIT } from "./code-highlighter";

const themes: [string, string] = ["github-light", "github-dark"];
const textOf = (value: { tokens: { content: string }[][] }) => value.tokens.map(line => line.map(token => token.content).join("")).join("\n");
const highlight = (plugin: ReturnType<typeof createCodeHighlighter>, code: string, language = "typescript") => new Promise<NonNullable<ReturnType<typeof plugin.highlight>>>(resolve => {
  const result = plugin.highlight({ code, language, themes }, resolve);
  if (result) resolve(result);
});
const fakeEngine = () => ({
  loadTheme: async () => {}, loadLanguage: async () => {}, dispose: () => {},
  codeToTokens: (code: string) => ({ tokens: code.split("\n").map(content => [{ content }]) }),
}) as unknown as Highlighter;

test("highlighting matches Shiki colors, aliases, Unicode and both themes", async () => {
  const plugin = createCodeHighlighter();
  try {
    const source = 'export const message: string = "世界 🌿";\nconsole.log(message);';
    const result = await highlight(plugin, source, " TS ");
    expect(textOf(result)).toBe(source);
    expect(result.tokens[0].some(token => token.htmlStyle?.color || token.color)).toBe(true);
    expect(plugin.supportsLanguage(" TS ")).toBe(true);
    expect(plugin.supportsLanguage("not-a-grammar")).toBe(false);
    expect(plugin.getSupportedLanguages()).toContain("zig");
    expect(plugin.getThemes()).toEqual(themes);
    expect(textOf(await highlight(plugin, source, "not-a-grammar"))).toBe(source);
  } finally { plugin.dispose(); }
});

test("equal-length middle edits never reuse another source's tokens", async () => {
  const plugin = createCodeHighlighter({ load: async () => fakeEngine() });
  const prefix = "p".repeat(110), suffix = "s".repeat(110);
  expect(textOf(await highlight(plugin, prefix + "FIRST" + suffix))).toContain("FIRST");
  expect(textOf(await highlight(plugin, prefix + "OTHER" + suffix))).toContain("OTHER");
  plugin.dispose();
});

test("custom themes with the same display name retain independent colors", async () => {
  const plugin = createCodeHighlighter({ maxEntries: 1 });
  const themed = (color: string) => ({ name: "Custom", type: "dark" as const, colors: { "editor.foreground": color, "editor.background": "#101010" }, tokenColors: [] });
  const red = themed("#ff0000"), green = themed("#00ff00");
  const run = (theme: typeof red) => new Promise<NonNullable<ReturnType<typeof plugin.highlight>>>(resolve => {
    const result = plugin.highlight({ code: "text", language: "text", themes: [theme, theme] }, resolve);
    if (result) resolve(result);
  });
  try {
    const first = await run(red), second = await run(green), restored = await run(red);
    expect(first.fg).not.toEqual(second.fg);
    expect(restored.fg).toEqual(first.fg);
  } finally { plugin.dispose(); }
});

test("streamed prefixes retain a cache bounded by bytes and entries", async () => {
  const plugin = createCodeHighlighter({ maxBytes: 9000, maxEntries: 4, load: async () => fakeEngine() });
  for (let n = 1; n < 100; n++) {
    await highlight(plugin, "const value = true;\n".repeat(n));
    expect(plugin.stats().entries).toBeLessThanOrEqual(4);
    expect(plugin.stats().bytes).toBeLessThanOrEqual(9000);
  }
  expect(plugin.stats().entries).toBeGreaterThan(0);
  plugin.dispose();
  expect(plugin.stats()).toEqual({ entries: 0, bytes: 0, pending: 0, pendingBytes: 0 });
});

test("LRU eviction keeps a recently used result and recomputes an older one", async () => {
  let calls = 0;
  const engine = fakeEngine();
  const render = engine.codeToTokens;
  engine.codeToTokens = ((...args: Parameters<typeof render>) => { calls++; return render(...args); }) as typeof render;
  const plugin = createCodeHighlighter({ maxEntries: 2, load: async () => engine });
  await highlight(plugin, "A"); await highlight(plugin, "B"); await highlight(plugin, "A"); await highlight(plugin, "C"); await highlight(plugin, "A");
  expect(calls).toBe(3);
  await highlight(plugin, "B"); expect(calls).toBe(4);
  plugin.dispose();
});

test("oversized fences preserve every character without loading a grammar or retaining tokens", () => {
  let loaded = false;
  const plugin = createCodeHighlighter({ load: async () => { loaded = true; return fakeEngine(); } });
  const source = "begin\n" + "λ".repeat(CODE_HIGHLIGHT_LIMIT) + "\nend";
  const result = plugin.highlight({ code: source, language: "typescript", themes });
  expect(textOf(result!)).toBe(source);
  expect(loaded).toBe(false);
  expect(plugin.stats().entries).toBe(0);
  plugin.dispose();
});

test("a warm highlighter failure preserves the complete code as plain text", async () => {
  const engine = fakeEngine();
  const plugin = createCodeHighlighter({ load: async () => engine });
  await highlight(plugin, "warm");
  engine.codeToTokens = () => { throw Error("Grammar failure"); };
  const source = "const value = 1;\n// complete source";
  expect(textOf(await highlight(plugin, source))).toBe(source);
  expect(plugin.stats().pending).toBe(0);
  plugin.dispose();
});

test("a slow cold grammar cannot overwrite a later warm result", async () => {
  const engine = fakeEngine();
  const plugin = createCodeHighlighter({ load: async () => engine });
  await highlight(plugin, "warm");
  let finish!: () => void;
  engine.loadLanguage = () => new Promise<void>(resolve => { finish = resolve; });
  const order: string[] = [];
  const cold = highlight(plugin, "old", "zig").then(result => order.push(textOf(result)));
  const warm = highlight(plugin, "warm").then(result => order.push(textOf(result)));
  await Promise.resolve(); await Promise.resolve();
  expect(order).toEqual([]);
  finish(); await Promise.all([cold, warm]);
  expect(order).toEqual(["old", "warm"]);
  plugin.dispose();
});

test("cold-load bursts release queued source within the pending budget", async () => {
  let finish!: (engine: Highlighter) => void;
  const plugin = createCodeHighlighter({ load: () => new Promise(resolve => { finish = resolve; }) });
  const requests = [];
  for (let n = 0; n < 80; n++) {
    requests.push(highlight(plugin, `// ${n}\n` + "x".repeat(40_000)));
    expect(plugin.stats().pending).toBeLessThanOrEqual(32);
    expect(plugin.stats().pendingBytes).toBeLessThanOrEqual(512 * 1024);
  }
  finish(fakeEngine());
  const results = await Promise.all(requests);
  expect(results.map(textOf).every((value, n) => value.startsWith(`// ${n}\n`))).toBe(true);
  expect(plugin.stats().pending).toBe(0);
  plugin.dispose();
});

test("disposing a pending highlighter releases callbacks and late engine initialization", async () => {
  let finish!: (engine: Highlighter) => void, callbacks = 0, disposals = 0;
  const engine = fakeEngine(); engine.dispose = () => { disposals++; };
  const plugin = createCodeHighlighter({ load: () => new Promise(resolve => { finish = resolve; }) });
  plugin.highlight({ code: "source", language: "typescript", themes }, () => { callbacks++; });
  plugin.dispose(); finish(engine);
  await Promise.resolve(); await Promise.resolve(); await Promise.resolve();
  expect(callbacks).toBe(0); expect(disposals).toBe(1);
  expect(plugin.stats().pendingBytes).toBe(0);
});

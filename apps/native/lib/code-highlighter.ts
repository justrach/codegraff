import { bundledLanguages, bundledLanguagesInfo, createHighlighter, type Highlighter, type BundledLanguage, type BundledTheme, type ThemeRegistrationAny } from "shiki";
import { createJavaScriptRegexEngine } from "shiki/engine/javascript";
import type { CodeHighlighterPlugin } from "streamdown";

type HighlightOptions = Parameters<CodeHighlighterPlugin["highlight"]>[0];
type HighlightResult = NonNullable<ReturnType<CodeHighlighterPlugin["highlight"]>>;
type Callback = (result: HighlightResult) => void;
type Engine = Pick<Highlighter, "loadLanguage" | "loadTheme" | "codeToTokens" | "dispose">;
type Entry = { result: HighlightResult; bytes: number };
type Request = { options: HighlightOptions; callback?: Callback; bytes: number };

export const CODE_CACHE_BYTES = 4 * 1024 * 1024;
export const CODE_CACHE_ENTRIES = 32;
export const CODE_HIGHLIGHT_LIMIT = 64 * 1024;
const PENDING_BYTES = 512 * 1024;
const PENDING_COUNT = 32;
const THEMES: HighlightOptions["themes"] = ["github-light", "github-dark"];
const languages = new Set(Object.keys(bundledLanguages));
const aliases = new Map(bundledLanguagesInfo.flatMap(language => (language.aliases ?? []).map(alias => [alias, language.id])));
const normalize = (language: string) => { const name = language.trim().toLowerCase(); return aliases.get(name) ?? name; };
const plain = (source: string): HighlightResult => ({ tokens: source.split("\n").map(content => [{ content }]) });

/** Keep only a bounded working set of tokens. A streamed fence otherwise caches
 * every prefix for the life of the renderer, including after its chat closes. */
export function createCodeHighlighter(options: {
  maxBytes?: number; maxEntries?: number;
  load?: () => Promise<Engine>;
} = {}) {
  const maxBytes = options.maxBytes ?? CODE_CACHE_BYTES, maxEntries = options.maxEntries ?? CODE_CACHE_ENTRIES;
  const cache = new Map<string, Entry>(), themeIds = new WeakMap<object, number>();
  const loadedLanguages = new Set<string>(), loadedThemes = new Set<string>();
  let themeSequence = 0, bytes = 0, pendingBytes = 0, draining = false, disposed = false;
  let engine: Engine | undefined, loading: Promise<Engine> | undefined;
  const pending: Request[] = [];
  const themeKey = (theme: HighlightOptions["themes"][number]) => {
    if (typeof theme === "string") return `name:${theme}`;
    let id = themeIds.get(theme);
    if (id === undefined) { id = ++themeSequence; themeIds.set(theme, id); }
    return `object:${id}`;
  };
  const themeName = (theme: HighlightOptions["themes"][number]) => typeof theme === "string" ? theme : `graff-theme-${themeKey(theme)}`;
  // Full source prevents collisions when equal-length edits share their edges.
  const keyFor = (value: HighlightOptions) => JSON.stringify([normalize(value.language), value.themes.map(themeKey), value.code]);
  const languageFor = (value: HighlightOptions) => { const name = normalize(value.language); return languages.has(name) ? name : "text"; };
  const ready = (value: HighlightOptions) => engine !== undefined &&
    (languageFor(value) === "text" || loadedLanguages.has(languageFor(value))) && value.themes.every(theme => loadedThemes.has(themeKey(theme)));
  const get = (key: string) => {
    const entry = cache.get(key);
    if (!entry) return null;
    cache.delete(key); cache.set(key, entry); return entry.result;
  };
  const retain = (key: string, result: HighlightResult) => {
    // Account for source, line arrays, tokens, colors and token-style records.
    // This is a conservative cache weight, not a claim about V8 object sizes.
    let weight = key.length * 2 + 256;
    for (const line of result.tokens) {
      weight += 64;
      for (const token of line) weight += 256 + token.content.length * 2 +
        Object.entries(token.htmlStyle ?? {}).reduce((sum, [name, value]) => sum + (name.length + value.length) * 2, 0);
    }
    if (weight > maxBytes || maxEntries < 1) return result;
    while (cache.size && (cache.size >= maxEntries || bytes + weight > maxBytes)) {
      const oldest = cache.keys().next().value!;
      bytes -= cache.get(oldest)!.bytes; cache.delete(oldest);
    }
    cache.set(key, { result, bytes: weight }); bytes += weight;
    return result;
  };
  const render = (value: HighlightOptions) => {
    if (value.code.length > CODE_HIGHLIGHT_LIMIT) return plain(value.code);
    const key = keyFor(value), existing = get(key);
    if (existing) return existing;
    const names = value.themes.map(themeName);
    const result = engine!.codeToTokens(value.code, { lang: languageFor(value) as BundledLanguage, themes: { light: names[0], dark: names[1] } });
    return retain(key, result);
  };
  const prepare = async (value: HighlightOptions) => {
    if (!loading) loading = (options.load ?? (() => createHighlighter({ themes: [], langs: [], engine: createJavaScriptRegexEngine({ forgiving: true }) })))();
    const current = await loading;
    if (disposed) { current.dispose(); return; }
    engine = current;
    const themes = value.themes.filter(theme => !loadedThemes.has(themeKey(theme)));
    if (themes.length) {
      await current.loadTheme(...themes.map(theme => typeof theme === "string" ? theme : { ...theme, name: themeName(theme) }) as (BundledTheme | ThemeRegistrationAny)[]);
      themes.forEach(theme => loadedThemes.add(themeKey(theme)));
    }
    const language = languageFor(value);
    if (language !== "text" && !loadedLanguages.has(language)) {
      await current.loadLanguage(language as BundledLanguage); loadedLanguages.add(language);
    }
  };
  const drain = async () => {
    if (draining || disposed) return;
    draining = true;
    try {
      while (pending.length && !disposed) {
        const request = pending[0];
        let result: HighlightResult;
        try {
          if (request.options.code.length <= CODE_HIGHLIGHT_LIMIT && !ready(request.options)) await prepare(request.options);
          // Overflow/disposal may have released this request while imports ran.
          if (pending[0] !== request || disposed) continue;
          result = render(request.options);
        } catch { result = plain(request.options.code); }
        if (pending[0] !== request || disposed) continue;
        pending.shift(); pendingBytes -= request.bytes;
        try { request.callback?.(result); } catch { /* A detached view must not block later requests. */ }
      }
    } finally { draining = false; }
  };
  const plugin: CodeHighlighterPlugin = {
    name: "shiki", type: "code-highlighter",
    getThemes: () => THEMES,
    getSupportedLanguages: () => [...languages],
    supportsLanguage: language => languages.has(normalize(language)),
    highlight(value, callback) {
      if (disposed) return plain(value.code);
      // Finish asynchronous requests in call order, including subsequent cache
      // hits. A cold grammar must not paint over a newer warm result.
      if (!pending.length && (value.code.length > CODE_HIGHLIGHT_LIMIT || ready(value))) {
        try { return render(value); } catch { return plain(value.code); }
      }
      const requestBytes = value.code.length * 2;
      if (pending.length >= PENDING_COUNT || pendingBytes + requestBytes > PENDING_BYTES) {
        const released = pending.splice(0); pendingBytes = 0;
        for (const request of released) {
          try { request.callback?.(plain(request.options.code)); } catch { /* Continue releasing detached views. */ }
        }
        return plain(value.code);
      }
      pending.push({ options: value, callback, bytes: requestBytes }); pendingBytes += requestBytes;
      void drain(); return null;
    },
  };
  return Object.assign(plugin, {
    stats: () => ({ entries: cache.size, bytes, pending: pending.length, pendingBytes }),
    dispose: () => { disposed = true; pending.length = 0; pendingBytes = 0; cache.clear(); bytes = 0; engine?.dispose(); },
  });
}

export const code = createCodeHighlighter();

export type Language =
  | "ts"
  | "js"
  | "py"
  | "rs"
  | "go"
  | "zig"
  | "json"
  | "css"
  | "shell"
  | "md"
  | "plain";

export type TokenType = "keyword" | "string" | "comment" | "number" | "punct" | "plain";

export interface Token {
  type: TokenType;
  value: string;
}

const EXT_TO_LANG: Record<string, Language> = {
  ts: "ts",
  tsx: "ts",
  mts: "ts",
  cts: "ts",
  js: "js",
  jsx: "js",
  mjs: "js",
  cjs: "js",
  py: "py",
  pyi: "py",
  rs: "rs",
  go: "go",
  zig: "zig",
  json: "json",
  css: "css",
  scss: "css",
  sh: "shell",
  bash: "shell",
  zsh: "shell",
  md: "md",
  markdown: "md",
};

export function languageFromPath(path: string): Language {
  const clean = path.replace(/\\/g, "/").split("/").pop() ?? "";
  const dot = clean.lastIndexOf(".");
  if (dot < 0) {
    return "plain";
  }
  const ext = clean.slice(dot + 1).toLowerCase();
  return EXT_TO_LANG[ext] ?? "plain";
}

// A shared base of common keywords plus a few per-language extras keeps the
// tokenizer tiny while still coloring the tokens people actually look at.
const BASE_KEYWORDS = [
  "if", "else", "for", "while", "return", "break", "continue", "switch",
  "case", "default", "true", "false", "null", "import", "export", "from",
  "as", "new", "try", "catch", "finally", "throw", "class", "extends",
];

const LANG_KEYWORDS: Record<Language, string[]> = {
  ts: [...BASE_KEYWORDS, "const", "let", "var", "function", "interface", "type", "enum", "async", "await", "public", "private", "readonly", "void", "this", "undefined", "namespace", "implements", "instanceof", "typeof", "in", "of", "yield"],
  js: [...BASE_KEYWORDS, "const", "let", "var", "function", "async", "await", "this", "undefined", "instanceof", "typeof", "in", "of", "yield"],
  py: ["def", "class", "if", "elif", "else", "for", "while", "return", "import", "from", "as", "try", "except", "finally", "raise", "with", "lambda", "yield", "async", "await", "None", "True", "False", "and", "or", "not", "in", "is", "pass", "global", "nonlocal"],
  rs: ["fn", "let", "mut", "const", "struct", "enum", "impl", "trait", "pub", "use", "mod", "match", "if", "else", "for", "while", "loop", "return", "self", "Self", "where", "async", "await", "move", "ref", "dyn", "as", "true", "false", "Some", "None", "Ok", "Err"],
  go: ["func", "var", "const", "type", "struct", "interface", "package", "import", "if", "else", "for", "range", "return", "switch", "case", "default", "go", "defer", "chan", "map", "nil", "true", "false"],
  zig: ["fn", "const", "var", "pub", "struct", "enum", "union", "if", "else", "for", "while", "switch", "return", "try", "catch", "defer", "errdefer", "comptime", "inline", "test", "and", "or", "null", "undefined", "true", "false", "void", "anytype"],
  json: ["true", "false", "null"],
  css: [],
  shell: ["if", "then", "else", "elif", "fi", "for", "while", "do", "done", "case", "esac", "function", "return", "export", "local", "echo"],
  md: [],
  plain: [],
};

function commentSyntax(lang: Language): { line: string | null; blockOpen: string | null; blockClose: string | null } {
  switch (lang) {
    case "py":
    case "shell":
      return { line: "#", blockOpen: null, blockClose: null };
    case "css":
      return { line: null, blockOpen: "/*", blockClose: "*/" };
    case "ts":
    case "js":
    case "rs":
    case "go":
    case "zig":
      return { line: "//", blockOpen: "/*", blockClose: "*/" };
    default:
      return { line: null, blockOpen: null, blockClose: null };
  }
}

const STRING_QUOTES = new Set(["\"", "'", "`"]);
const IDENT_START = /[A-Za-z_$]/;
const IDENT_PART = /[A-Za-z0-9_$]/;
const PUNCT = /[{}()[\].,;:=+\-*/%<>!&|^~?@#]/;

/**
 * Tokenize a single line for basic syntax coloring. Per-line only — multi-line
 * strings/comments are not tracked across lines, which keeps this dependency-free
 * and fast for diff rendering.
 */
export function tokenizeLine(line: string, lang: Language): Token[] {
  if (lang === "plain" || line.length === 0) {
    return line.length === 0 ? [] : [{ type: "plain", value: line }];
  }

  const keywords = new Set(LANG_KEYWORDS[lang]);
  const { line: lineComment, blockOpen } = commentSyntax(lang);
  const tokens: Token[] = [];
  let i = 0;
  const n = line.length;

  const pushPlain = (value: string) => {
    const last = tokens[tokens.length - 1];
    if (last != null && last.type === "plain") {
      last.value += value;
    } else {
      tokens.push({ type: "plain", value });
    }
  };

  while (i < n) {
    const rest = line.slice(i);

    // Line comment -> rest of line.
    if (lineComment != null && rest.startsWith(lineComment)) {
      tokens.push({ type: "comment", value: rest });
      break;
    }

    // Block comment open -> consume to close or end of line (per-line only).
    if (blockOpen != null && rest.startsWith(blockOpen)) {
      const closeIdx = rest.indexOf("*/", blockOpen.length);
      const end = closeIdx >= 0 ? closeIdx + 2 : rest.length;
      tokens.push({ type: "comment", value: rest.slice(0, end) });
      i += end;
      continue;
    }

    const ch = line[i]!;

    // Strings.
    if (STRING_QUOTES.has(ch)) {
      let j = i + 1;
      while (j < n) {
        if (line[j] === "\\") {
          j += 2;
          continue;
        }
        if (line[j] === ch) {
          j += 1;
          break;
        }
        j += 1;
      }
      tokens.push({ type: "string", value: line.slice(i, j) });
      i = j;
      continue;
    }

    // Numbers.
    if (/[0-9]/.test(ch)) {
      let j = i + 1;
      while (j < n && /[0-9a-fA-FxXoObB._]/.test(line[j]!)) {
        j += 1;
      }
      tokens.push({ type: "number", value: line.slice(i, j) });
      i = j;
      continue;
    }

    // Identifiers / keywords.
    if (IDENT_START.test(ch)) {
      let j = i + 1;
      while (j < n && IDENT_PART.test(line[j]!)) {
        j += 1;
      }
      const word = line.slice(i, j);
      tokens.push({ type: keywords.has(word) ? "keyword" : "plain", value: word });
      i = j;
      continue;
    }

    // Punctuation.
    if (PUNCT.test(ch)) {
      tokens.push({ type: "punct", value: ch });
      i += 1;
      continue;
    }

    pushPlain(ch);
    i += 1;
  }

  return tokens;
}

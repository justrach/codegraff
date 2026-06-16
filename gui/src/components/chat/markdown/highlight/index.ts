import { SugarHigh, tokenize } from "./sugar-high";

export interface HighlightToken {
  /** CSS class for the token, e.g. "sh-keyword". "break" tokens are newlines. */
  className: string;
  value: string;
}

const TOKEN_TYPES = SugarHigh.TokenTypes;

/**
 * Tokenize source into highlight spans. The tokenizer is JS/TS-tuned but emits
 * generic identifier/string/comment/number/sign tokens that read reasonably for
 * most C-like languages. Coloring is driven by `.sh-*` CSS classes (see index.css).
 */
export function tokenizeCode(code: string): HighlightToken[] {
  return tokenize(code).map(([type, value]) => ({
    className: `sh-${TOKEN_TYPES[type] ?? "identifier"}`,
    value,
  }));
}

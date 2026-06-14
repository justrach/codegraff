// Type declarations for the vendored sugar-high.js (subset we use).
// Upstream: https://github.com/huozhi/sugar-high (MIT).

/** Ordered token-type names; a token's numeric type indexes into this list. */
export declare const SugarHigh: {
  readonly TokenTypes: readonly string[];
  readonly TokenMap: ReadonlyMap<string, number>;
};

export interface TokenizeOptions {
  keywords?: Set<string>;
  typeKeywords?: Set<string>;
}

/** Returns `[typeIndex, tokenString]` pairs. `typeIndex` indexes SugarHigh.TokenTypes. */
export declare function tokenize(
  code: string,
  options?: TokenizeOptions,
): Array<[number, string]>;

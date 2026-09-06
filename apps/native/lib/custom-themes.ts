export const bases = ["light", "dark", "website", "codegraff"] as const;
export type BuiltinAppearance = typeof bases[number];
export const colorTokens = ["page", "canvas", "surface", "inset", "hover", "hover-2", "ink", "ink-2", "ink-3", "line", "line-strong", "field", "stripe", "stripe-bg", "accent", "accent-ink", "accent-tint", "green", "green-tint", "red", "red-tint", "orange", "orange-tint", "brand-coral", "brand-gold"] as const;
export const fonts = { geist: 'var(--font-inter), system-ui, sans-serif', system: '-apple-system, BlinkMacSystemFont, sans-serif', serif: 'Georgia, "Times New Roman", serif' };
export type CustomTheme = { version: 1; id: string; name: string; base: BuiltinAppearance; colors: Partial<Record<typeof colorTokens[number], string>>; font?: keyof typeof fonts; corners?: number };
export const themeLimit = 16 * 1024;
const record = (value: unknown): value is Record<string, unknown> => !!value && typeof value === "object" && !Array.isArray(value);
export function parseTheme(value: unknown): CustomTheme {
  if (!record(value) || value.version !== 1) throw Error("Use theme version 1.");
  if (Object.keys(value).some(key => !["version", "id", "name", "base", "colors", "font", "corners"].includes(key))) throw Error("Theme contains an unknown setting.");
  if (typeof value.id !== "string" || !/^[a-z][a-z0-9-]{0,47}$/.test(value.id)) throw Error("Theme id must be a lowercase name with letters, digits or hyphens (up to 48 characters).");
  if (typeof value.name !== "string" || !value.name.trim() || value.name.length > 60 || /[\x00-\x1f]/.test(value.name)) throw Error("Give the theme a name of 1–60 characters.");
  if (!bases.includes(value.base as BuiltinAppearance)) throw Error("Choose a base: light, dark, website or codegraff.");
  if (!record(value.colors)) throw Error("Theme colors must be an object.");
  const colors: CustomTheme["colors"] = {};
  for (const [key, color] of Object.entries(value.colors)) {
    if (!(colorTokens as readonly string[]).includes(key) || typeof color !== "string" || !/^#[0-9a-f]{6}$/i.test(color)) throw Error(`Invalid color: ${key}. Use a supported token and a six-digit hex color.`);
    colors[key as keyof typeof colors] = color;
  }
  for (const key of ["page", "surface", "ink", "ink-2", "ink-3", "accent", "accent-ink", "accent-tint"] as const) if (!colors[key]) throw Error(`Missing color: ${key}.`);
  if (value.font !== undefined && (typeof value.font !== "string" || !Object.hasOwn(fonts, value.font))) throw Error("Font must be geist, system or serif.");
  if (value.corners !== undefined && (typeof value.corners !== "number" || !Number.isInteger(value.corners) || value.corners < 0 || value.corners > 20)) throw Error("Corners must be a whole number from 0 to 20.");
  return { version: 1, id: value.id, name: value.name.trim(), base: value.base as BuiltinAppearance, colors, ...(value.font === undefined ? {} : { font: value.font as keyof typeof fonts }), ...(value.corners === undefined ? {} : { corners: value.corners as number }) };
}
export function contrast(a: string, b: string) {
  const luminance = (hex: string) => [1, 3, 5].map(at => parseInt(hex.slice(at, at + 2), 16) / 255).map(c => c <= .04045 ? c / 12.92 : ((c + .055) / 1.055) ** 2.4).reduce((sum, c, i) => sum + c * [.2126, .7152, .0722][i], 0);
  const x = luminance(a), y = luminance(b); return (Math.max(x, y) + .05) / (Math.min(x, y) + .05);
}
export function themeWarnings(theme: CustomTheme): string[] {
  const warnings: string[] = [];
  for (const ink of ["ink", "ink-2", "ink-3", "accent-ink"] as const) {
    for (const background of ["page", "surface"] as const) if (contrast(theme.colors[ink]!, theme.colors[background]!) < 4.5) warnings.push(`${ink} on ${background} has low text contrast.`);
  }
  return warnings;
}

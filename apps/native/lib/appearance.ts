import { colorTokens, fonts, parseTheme, type CustomTheme, type BuiltinAppearance } from "./custom-themes";
export type Appearance = BuiltinAppearance | `custom:${string}`;
export const customThemeKey = "bui-custom-theme";
export const appearanceKey = "bui-theme";
export const appearanceEvent = "graff-appearance";
export function normalizeAppearance(value: string | null): Appearance {
  if (value && /^custom:[a-z][a-z0-9-]{0,47}$/.test(value)) return value as Appearance;
  return value === "light" || value === "website" || value === "codegraff" ? value : "dark";
}
export function readAppearance(): Appearance {
  try { return normalizeAppearance(localStorage.getItem(appearanceKey)); }
  catch { return normalizeAppearance(document.documentElement.dataset.theme ?? null); }
}
export function applyAppearance(theme: Appearance) {
  const root = document.documentElement;
  let custom: CustomTheme | null = null;
  if (theme.startsWith("custom:")) try { const saved = parseTheme(JSON.parse(localStorage.getItem(customThemeKey) || "null")); if (`custom:${saved.id}` === theme) custom = saved; } catch {}
  const base = custom?.base ?? (theme.startsWith("custom:") ? "dark" : theme);
  root.classList.toggle("dark", base === "dark");
  root.dataset.theme = base;
  root.dataset.appearance = theme;
  root.style.colorScheme = base === "dark" ? "dark" : "light";
  for (const token of colorTokens) root.style.removeProperty(`--${token}`);
  for (const token of ["chip", "control", "card"]) root.style.removeProperty(`--radius-${token}`);
  if (document.body) document.body.style.fontFamily = "";
  if (custom) {
    for (const [token, color] of Object.entries(custom.colors)) root.style.setProperty(`--${token}`, color);
    if (custom.corners !== undefined) for (const token of ["chip", "control", "card"]) root.style.setProperty(`--radius-${token}`, `${custom.corners}px`);
    if (custom.font && document.body) document.body.style.fontFamily = fonts[custom.font];
  }
}
export function selectCustomTheme(theme: CustomTheme) {
  const valid = parseTheme(theme);
  localStorage.setItem(customThemeKey, JSON.stringify(valid));
  localStorage.setItem(appearanceKey, `custom:${valid.id}`);
  applyAppearance(`custom:${valid.id}`); window.dispatchEvent(new Event(appearanceEvent));
}
// Run before paint as well as after hydration to avoid flashing the default theme.
export const appearanceScript = `(()=>{const root=document.documentElement;let theme="dark",custom=null;try{theme=localStorage.getItem("${appearanceKey}")||"dark";if(theme.startsWith("custom:")){const c=JSON.parse(localStorage.getItem("${customThemeKey}")||"null");if(c&&theme==="custom:"+c.id&&["light","dark","website","codegraff"].includes(c.base)&&c.colors)custom=c}}catch{}const base=custom?custom.base:["light","website","codegraff"].includes(theme)?theme:"dark";root.dataset.theme=base;root.classList.toggle("dark",base==="dark");root.style.colorScheme=base==="dark"?"dark":"light";if(custom)for(const [key,value]of Object.entries(custom.colors))if(${JSON.stringify(colorTokens)}.includes(key)&&typeof value==="string"&&/^#[0-9a-f]{6}$/i.test(value))root.style.setProperty("--"+key,value)})()`;

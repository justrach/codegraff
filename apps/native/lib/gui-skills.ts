// This catalog belongs to the desktop composer, never the engine's skill registry.
export const guiSkills = [{ id: "gui-theme", name: "GUI theme", description: "Create or adjust your desktop theme" }] as const;
export function guiSkillRows(query: string) {
  return guiSkills.filter(skill => `${skill.id} ${skill.description}`.toLowerCase().includes(query.toLowerCase())).map(skill => ({ key: `gui-skill:${skill.id}`, name: `$${skill.id}`, desc: `GUI skill · ${skill.description}` }));
}
export function selectedGuiSkills(text: string) {
  const prose = text.replace(/```[\s\S]*?(?:```|$)|`[^`\n]*`/g, "");
  return guiSkills.filter(skill => new RegExp(`(?:^|\\s)[@$]${skill.id}(?=$|\\s|[.,!?;:])`).test(prose));
}
export function parseComposerToken(draft: string): { kind: "at" | "slash" | "skill"; query: string; start: number } | null {
  const match = /(^|\s)([@/$])([\w./-]*)$/.exec(draft);
  return match ? { kind: match[2] === "@" ? "at" : match[2] === "$" ? "skill" : "slash", query: match[3].toLowerCase(), start: match.index + match[1].length } : null;
}
const start = "\n<graff-gui-skill-context>\n", end = "\n</graff-gui-skill-context>";
export function withGuiSkillContext(text: string, instructions: string) { return `${text}${start}${instructions}${end}`; }
export function withoutGuiSkillContext(text: string) {
  const at = text.lastIndexOf(start);
  return at >= 0 && text.endsWith(end) ? text.slice(0, at) : text;
}

import { readFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { selectedGuiSkills, withGuiSkillContext } from "./gui-skills";
import { themeDirectory } from "./theme-files";

function mcpConfigPaths() {
  const user = process.env.GRAFF_MCP_CONFIG || path.join(os.homedir(), ".codegraff", "mcp.json");
  const root = process.env.GRAFF_ACP_CWD || process.env.GRAFF_CWD || process.cwd();
  return { user, local: path.join(root, ".mcp.json") };
}

function extraFor(id: string): string {
  if (id === "theme") return `Theme directory for this desktop: ${JSON.stringify(themeDirectory())}`;
  if (id === "mcp") {
    const paths = mcpConfigPaths();
    return `User MCP config for this desktop: ${JSON.stringify(paths.user)}\nWorkspace MCP config for this desktop: ${JSON.stringify(paths.local)}`;
  }
  return "";
}

export async function prepareGuiPrompt(params: Record<string, unknown> | undefined) {
  if (!Array.isArray(params?.prompt)) return params;
  const selected = new Set<string>();
  // Explicit mentions in user text only: attachments never activate a skill.
  for (const block of params.prompt) if (block?.type === "text" && typeof block.text === "string") for (const skill of selectedGuiSkills(block.text)) selected.add(skill.id);
  if (!selected.size) return params;
  const instructions = await Promise.all([...selected].map(async id => {
    const text = await readFile(path.join(process.cwd(), "skills", id, "SKILL.md"), "utf8");
    const extra = extraFor(id);
    return `GUI skill: ${id}\n${text.replace(/^---\r?\n[\s\S]*?\r?\n---\r?\n/, "")}${extra ? `\n${extra}` : ""}`;
  }));
  const prompt = params.prompt.map(block => ({ ...block }));
  const first = prompt.find(block => block.type === "text" && typeof block.text === "string");
  first.text = withGuiSkillContext(first.text, instructions.join("\n\n"));
  return { ...params, prompt };
}

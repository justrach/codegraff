import { open, readdir, mkdir, link, rm } from "node:fs/promises";
import { constants } from "node:fs";
import path from "node:path";
import os from "node:os";
import { randomUUID } from "node:crypto";
import { parseTheme, themeLimit, themeWarnings, type CustomTheme } from "./custom-themes";

export const themeDirectory = () => process.env.GRAFF_THEMES_DIR || path.join(os.homedir(), ".graff", "themes");
export async function readThemeFile(file: string) {
  const handle = await open(file, constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const stat = await handle.stat();
    if (!stat.isFile() || stat.size > themeLimit) throw Error("Theme must be a JSON file smaller than 16 KiB.");
    const buffer = Buffer.alloc(themeLimit + 1);
    const { bytesRead } = await handle.read(buffer, 0, buffer.length, 0);
    if (bytesRead > themeLimit) throw Error("Theme is too large.");
    return parseTheme(JSON.parse(buffer.subarray(0, bytesRead).toString("utf8")));
  } finally { await handle.close(); }
}
export async function listThemes(directory = themeDirectory()) {
  const themes: CustomTheme[] = [], issues: string[] = [];
  let files;
  try { files = await readdir(directory, { withFileTypes: true }); }
  catch (error) { if ((error as NodeJS.ErrnoException).code === "ENOENT") return { themes, issues }; throw error; }
  const candidates = files.filter(file => file.name.endsWith(".json")).sort((a, b) => a.name.localeCompare(b.name));
  if (candidates.length > 100) issues.push("Only the first 100 theme files are loaded.");
  for (const file of candidates.slice(0, 100)) {
    try {
      const theme = await readThemeFile(path.join(directory, file.name));
      if (file.name !== `${theme.id}.json`) throw Error("Filename must match the theme id.");
      themes.push(theme);
    } catch (error) { issues.push(`${file.name}: ${error instanceof Error ? error.message : "Could not read theme."}`); }
  }
  return { themes, issues };
}
export async function saveTheme(value: unknown, directory = themeDirectory()) {
  const theme = parseTheme(value);
  await mkdir(directory, { recursive: true, mode: 0o700 });
  const file = path.join(directory, `${theme.id}.json`), temp = path.join(directory, `.${randomUUID()}.tmp`);
  try {
    const handle = await open(temp, "wx", 0o600);
    try { await handle.writeFile(JSON.stringify(theme, null, 2) + "\n"); } finally { await handle.close(); }
    // Import creates a new choice; it cannot overwrite an existing theme.
    await link(temp, file);
  } finally { await rm(temp, { force: true }); }
  return { theme, warnings: themeWarnings(theme) };
}

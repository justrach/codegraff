/** Short labels for transcript file chips. A wall of worktree prefixes is noise. */

export const DIFF_CHIP_CAP = 3;

export function pathParts(file: string): string[] {
  return file.split(/[/\\]/).filter(Boolean);
}

export function fileBase(file: string): string {
  const parts = pathParts(file);
  return parts[parts.length - 1] || file;
}

/** Basename, or `parent/basename` when two chips would otherwise collide. */
export function diffChipLabels(files: string[]): string[] {
  const bases = files.map(fileBase);
  return files.map((file, index) => {
    const base = bases[index];
    if (!base || bases.filter((item) => item === base).length < 2) return base || file;
    const parts = pathParts(file);
    const peers = files.filter((_, peer) => bases[peer] === base);
    for (let depth = 2; depth <= parts.length; depth++) {
      const label = parts.slice(-depth).join("/");
      const same = peers.filter((peer) => pathParts(peer).slice(-depth).join("/") === label);
      if (same.length === 1) return label;
    }
    return file;
  });
}

export function shortPath(file: string, peers: string[]): string {
  const index = peers.indexOf(file);
  return index >= 0 ? diffChipLabels(peers)[index] : fileBase(file);
}

/** ACP stamps every edit +1 −1. That pair is not a measured diff. */
export function meaningfulDiffStat(add: number, del: number): boolean {
  return add > 1 || del > 1;
}

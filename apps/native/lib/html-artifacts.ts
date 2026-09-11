/** Parse only an opaque saved result reference; never a file path or remote URL. */
export function htmlArtifactId(text: string): string | undefined {
  return /\[HTML preview\]\(graff-html:([a-f0-9]{32})\)/.exec(text)?.[1];
}

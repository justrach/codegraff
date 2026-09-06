import { open } from "node:fs/promises";
export const MAX_PREVIEW = 256 * 1024;
/** Read only the displayed prefix, including for huge logs and sparse files. */
export async function filePreview(path: string) {
  const file = await open(path, "r");
  try {
    const { size } = await file.stat();
    const buffer = Buffer.alloc(Math.min(size, MAX_PREVIEW));
    const { bytesRead } = await file.read(buffer, 0, buffer.length, 0);
    const bytes = buffer.subarray(0, bytesRead);
    const binary = bytes.subarray(0, 8192).includes(0);
    return { size, binary, truncated: size > bytesRead, text: binary ? "" : bytes.toString("utf8") };
  } finally { await file.close(); }
}

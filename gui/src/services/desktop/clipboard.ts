import { invoke } from "@tauri-apps/api/core";
import { isQaMockMode, mockInvokeCommand } from "./clientQaMock";

/** Save clipboard pixels, recording application ownership before returning. */
export function savePastedImage(data: number[], ext: string): Promise<string> {
  return isQaMockMode
    ? mockInvokeCommand("save_pasted_image", { data, ext })
    : invoke("save_pasted_image", { data, ext });
}

/** Discard only a recorded unsent export; original files remain untouched. */
export function discardPastedImage(path: string): Promise<void> {
  return isQaMockMode
    ? mockInvokeCommand("discard_pasted_image", { path })
    : invoke("discard_pasted_image", { path });
}

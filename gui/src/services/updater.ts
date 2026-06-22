import { ask, message } from "@tauri-apps/plugin-dialog";
import { relaunch } from "@tauri-apps/plugin-process";
import { check } from "@tauri-apps/plugin-updater";

let inFlight = false;

/**
 * Check GitHub for a newer desktop build and, if one exists, offer to install
 * it. Downloads the signed updater artifact (verified against the bundled
 * minisign public key), applies it, and relaunches.
 *
 * The updater endpoint and pubkey live in `src-tauri/tauri.conf.json`. This
 * complements the CLI's `graff update`: that updates only the bundled `graff`
 * binary, while this swaps the whole desktop app.
 *
 * @param silent When true (the on-launch path) stay quiet if already current or
 *   if the check fails. The manual "Check for Updates" path passes false so the
 *   user always gets feedback.
 */
export async function checkForUpdates({ silent = true }: { silent?: boolean } = {}): Promise<void> {
  if (inFlight) return;
  inFlight = true;
  try {
    const update = await check();
    if (!update) {
      if (!silent) {
        await message("You're on the latest version of Codegraff.", {
          title: "Codegraff",
          kind: "info",
        });
      }
      return;
    }

    const accepted = await ask(
      `Codegraff ${update.version} is available (you have ${update.currentVersion}).\n\nInstall it now and relaunch?`,
      {
        title: "Update available",
        kind: "info",
        okLabel: "Install & Relaunch",
        cancelLabel: "Later",
      },
    );
    if (!accepted) return;

    await update.downloadAndInstall();
    await relaunch();
  } catch (err) {
    if (silent) {
      console.error("[updater] check failed", err);
    } else {
      await message(`Update check failed: ${String(err)}`, {
        title: "Codegraff",
        kind: "error",
      });
    }
  } finally {
    inFlight = false;
  }
}

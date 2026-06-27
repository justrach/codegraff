let inFlight = false;

/**
 * Keep the update entry point available so release-parity UI can call it, but
 * defer the actual desktop-app updater until the native shell exposes an updater
 * command.
 */
export async function checkForUpdates({ silent = true }: { silent?: boolean } = {}): Promise<void> {
  if (inFlight) return;
  inFlight = true;
  try {
    if (!silent) {
      window.alert(
        "Desktop app updates are not available in this native build yet. Use `graff update --check` for the bundled CLI.",
      );
    }
  } finally {
    inFlight = false;
  }
}

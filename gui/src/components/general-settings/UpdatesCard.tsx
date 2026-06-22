import { useEffect, useState } from "react";
import { getVersion } from "@tauri-apps/api/app";
import { relaunch } from "@tauri-apps/plugin-process";
import { check, type Update } from "@tauri-apps/plugin-updater";
import { DownloadIcon, RefreshCwIcon } from "lucide-react";

import { Button } from "@/components/ui/Button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/Card";

type Status =
  | { kind: "idle" }
  | { kind: "checking" }
  | { kind: "upToDate" }
  | { kind: "available"; update: Update }
  | { kind: "installing" }
  | { kind: "error"; message: string };

/**
 * Manual update control for the desktop app. The app also auto-checks on launch
 * (see services/updater.ts), but this gives a discoverable "Check for updates"
 * button plus the current version, and installs in-place via the Tauri updater.
 */
export function UpdatesCard() {
  const [version, setVersion] = useState("");
  const [status, setStatus] = useState<Status>({ kind: "idle" });

  useEffect(() => {
    getVersion()
      .then(setVersion)
      .catch(() => {});
  }, []);

  async function handleCheck() {
    setStatus({ kind: "checking" });
    try {
      const update = await check();
      setStatus(update ? { kind: "available", update } : { kind: "upToDate" });
    } catch (err) {
      setStatus({ kind: "error", message: String(err) });
    }
  }

  async function handleInstall() {
    if (status.kind !== "available") {
      return;
    }
    const { update } = status;
    setStatus({ kind: "installing" });
    try {
      await update.downloadAndInstall();
      await relaunch();
    } catch (err) {
      setStatus({ kind: "error", message: String(err) });
    }
  }

  const busy = status.kind === "checking" || status.kind === "installing";

  return (
    <Card>
      <CardHeader>
        <CardTitle>Updates</CardTitle>
      </CardHeader>
      <CardContent className="flex items-center justify-between gap-3">
        <div className="flex min-w-0 flex-col">
          <span className="text-sm text-foreground">
            Codegraff{version ? ` ${version}` : ""}
          </span>
          <span className="text-xs text-muted-foreground">
            {statusText(status)}
          </span>
        </div>
        {status.kind === "available" ? (
          <Button
            type="button"
            size="sm"
            onClick={handleInstall}
            disabled={busy}
          >
            <DownloadIcon data-icon="inline-start" strokeWidth={2} />
            Install &amp; relaunch
          </Button>
        ) : (
          <Button
            type="button"
            size="sm"
            variant="secondary"
            onClick={handleCheck}
            disabled={busy}
          >
            <RefreshCwIcon
              data-icon="inline-start"
              strokeWidth={2}
              className={status.kind === "checking" ? "animate-spin" : undefined}
            />
            Check for updates
          </Button>
        )}
      </CardContent>
    </Card>
  );
}

function statusText(status: Status): string {
  switch (status.kind) {
    case "checking":
      return "Checking for updates…";
    case "upToDate":
      return "You're on the latest version.";
    case "available":
      return `Version ${status.update.version} is available.`;
    case "installing":
      return "Downloading and installing…";
    case "error":
      return `Couldn't check for updates: ${status.message}`;
    default:
      return "Updates install automatically on launch; check manually any time.";
  }
}

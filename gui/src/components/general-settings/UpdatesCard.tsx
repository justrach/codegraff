import { useState } from "react";
import { RefreshCwIcon } from "lucide-react";

import { Button } from "@/components/ui/Button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/Card";
import { checkForUpdates } from "@/services/updater";

type Status =
  | { kind: "idle" }
  | { kind: "checking" }
  | { kind: "nativeUpdaterUnavailable" }
  | { kind: "error"; message: string };

/**
 * Manual update control for the native desktop app. Native desktop updates are
 * not wired yet, so this surfaces the parity entry point while directing users
 * to the CLI updater.
 */
export function UpdatesCard() {
  const [status, setStatus] = useState<Status>({ kind: "idle" });

  async function handleCheck() {
    setStatus({ kind: "checking" });
    try {
      await checkForUpdates({ silent: false });
      setStatus({ kind: "nativeUpdaterUnavailable" });
    } catch (err) {
      setStatus({ kind: "error", message: String(err) });
    }
  }

  const busy = status.kind === "checking";

  return (
    <Card>
      <CardHeader>
        <CardTitle>Updates</CardTitle>
      </CardHeader>
      <CardContent className="flex items-center justify-between gap-3">
        <div className="flex min-w-0 flex-col">
          <span className="text-sm text-foreground">Codegraff</span>
          <span className="text-xs text-muted-foreground">
            {statusText(status)}
          </span>
        </div>
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
      </CardContent>
    </Card>
  );
}

function statusText(status: Status): string {
  switch (status.kind) {
    case "checking":
      return "Checking for updates…";
    case "nativeUpdaterUnavailable":
      return "Use `graff update --check` to check the bundled CLI.";
    case "error":
      return `Couldn't check for updates: ${status.message}`;
    default:
      return "Native app updates are not wired yet; CLI updates use `graff update`.";
  }
}

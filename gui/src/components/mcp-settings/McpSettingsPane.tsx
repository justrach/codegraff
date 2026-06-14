import { useEffect, useMemo, useState } from "react";
import {
  LoaderCircle,
  LogInIcon,
  LogOutIcon,
  RefreshCwIcon,
  Trash2Icon,
} from "lucide-react";

import { getUiActiveWorkspacePath } from "@/app/sessionStore";
import { useSessionStore } from "@/hooks/useSession";
import {
  importMcpConfig,
  listMcpServers,
  loginMcpServer,
  logoutMcpServer,
  reloadMcpServers,
  removeMcpServer,
} from "@/services/desktop/client";
import type { McpSettingsPayload } from "@/services/desktop/types/contracts";
import { Button } from "@/components/ui/Button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/Card";
import { PaneSurface } from "@/components/ui/PaneSurface";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/Select";
import { Textarea } from "@/components/ui/Textarea";

type McpScope = "user" | "local";

export function McpSettingsPane() {
  const workspacePath = useSessionStore((state) =>
    getUiActiveWorkspacePath(state),
  );
  const [payload, setPayload] = useState<McpSettingsPayload | null>(null);
  const [isLoading, setIsLoading] = useState(true);
  const [actionError, setActionError] = useState<string | null>(null);
  const [jsonDraft, setJsonDraft] = useState("");
  const [scope, setScope] = useState<McpScope>("user");
  const [busyAction, setBusyAction] = useState<string | null>(null);

  const sortedServers = useMemo(
    () =>
      [...(payload?.servers ?? [])].sort((a, b) =>
        a.name.localeCompare(b.name),
      ),
    [payload?.servers],
  );

  useEffect(() => {
    let isCancelled = false;

    async function loadServers() {
      setIsLoading(true);
      setActionError(null);
      try {
        const nextPayload = await listMcpServers(workspacePath);
        if (!isCancelled) {
          setPayload(nextPayload);
        }
      } catch (error) {
        if (!isCancelled) {
          setPayload(null);
          setActionError(error instanceof Error ? error.message : String(error));
        }
      } finally {
        if (!isCancelled) {
          setIsLoading(false);
        }
      }
    }

    void loadServers();

    return () => {
      isCancelled = true;
    };
  }, [workspacePath]);

  async function runAction(name: string, action: () => Promise<McpSettingsPayload>) {
    setBusyAction(name);
    setActionError(null);
    try {
      setPayload(await action());
    } catch (error) {
      setActionError(error instanceof Error ? error.message : String(error));
    } finally {
      setBusyAction(null);
    }
  }

  return (
    <PaneSurface className="flex-1" aria-label="MCP settings">
      <div className="mx-auto flex h-full min-h-0 w-full max-w-4xl flex-col gap-4 overflow-y-auto px-6 pt-6 pb-12">
        <div className="flex items-center justify-between gap-3">
          <div className="flex flex-col gap-1">
            <h1 className="text-lg font-medium text-foreground">MCP</h1>
            <p className="max-w-xl text-sm text-muted-foreground">
              Manage configured Model Context Protocol servers.
            </p>
          </div>
          <Button
            type="button"
            variant="outline"
            disabled={isLoading || busyAction != null}
            onClick={() => {
              void runAction("reload", () => reloadMcpServers(workspacePath));
            }}
          >
            {busyAction === "reload" ? (
              <LoaderCircle data-icon="inline-start" className="animate-spin" />
            ) : (
              <RefreshCwIcon data-icon="inline-start" />
            )}
            Reload
          </Button>
        </div>

        {actionError != null ? (
          <div className="rounded-md border border-destructive/30 bg-destructive/5 px-3 py-2 text-sm text-destructive">
            {actionError}
          </div>
        ) : null}

        <Card>
          <CardHeader>
            <CardTitle>Servers</CardTitle>
          </CardHeader>
          <CardContent className="grid gap-2">
            {isLoading ? (
              <div className="flex h-20 items-center justify-center">
                <LoaderCircle className="size-4 animate-spin text-muted-foreground" />
              </div>
            ) : sortedServers.length === 0 ? (
              <p className="text-sm text-muted-foreground">
                No MCP servers configured.
              </p>
            ) : (
              sortedServers.map((server) => (
                <div
                  key={server.name}
                  className="grid gap-2 rounded-md border border-border p-3"
                >
                  <div className="flex min-w-0 items-start justify-between gap-3">
                    <div className="min-w-0">
                      <div className="flex items-center gap-2">
                        <span className="font-medium">{server.name}</span>
                        <span className="rounded bg-secondary px-1.5 py-0.5 text-[10px] text-muted-foreground">
                          {server.serverType}
                        </span>
                        {server.isDisabled ? (
                          <span className="rounded bg-destructive/10 px-1.5 py-0.5 text-[10px] text-destructive">
                            disabled
                          </span>
                        ) : null}
                      </div>
                      <p className="truncate font-mono text-[11px] text-muted-foreground">
                        {server.target}
                      </p>
                    </div>
                    <div className="flex shrink-0 items-center gap-1">
                      {server.authStatus != null ? (
                        <>
                          <Button
                            type="button"
                            variant="outline"
                            size="sm"
                            disabled={busyAction != null}
                            onClick={() => {
                              void runAction(`login:${server.name}`, () =>
                                loginMcpServer({ name: server.name, scope: null }),
                              );
                            }}
                          >
                            <LogInIcon data-icon="inline-start" />
                            Login
                          </Button>
                          <Button
                            type="button"
                            variant="outline"
                            size="sm"
                            disabled={busyAction != null}
                            onClick={() => {
                              void runAction(`logout:${server.name}`, () =>
                                logoutMcpServer({
                                  name: server.name,
                                  scope: null,
                                }),
                              );
                            }}
                          >
                            <LogOutIcon data-icon="inline-start" />
                            Logout
                          </Button>
                        </>
                      ) : null}
                      <Button
                        type="button"
                        variant="ghost"
                        size="icon-sm"
                        aria-label={`Remove ${server.name}`}
                        disabled={busyAction != null}
                        onClick={() => {
                          void runAction(`remove:${server.name}`, () =>
                            removeMcpServer({ name: server.name, scope }),
                          );
                        }}
                      >
                        <Trash2Icon />
                      </Button>
                    </div>
                  </div>
                  <div className="flex flex-wrap gap-2 text-xs text-muted-foreground">
                    <span>{server.toolCount} tools</span>
                    {server.authStatus != null ? (
                      <span>auth: {server.authStatus}</span>
                    ) : null}
                    {server.error != null ? (
                      <span className="text-destructive">{server.error}</span>
                    ) : null}
                  </div>
                </div>
              ))
            )}
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>Import</CardTitle>
          </CardHeader>
          <CardContent className="grid gap-3">
            <div className="flex items-center gap-2">
              <Select
                value={scope}
                onValueChange={(value) => {
                  setScope((value as McpScope | undefined) ?? "user");
                }}
              >
                <SelectTrigger className="w-32">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="user">User</SelectItem>
                  <SelectItem value="local">Local</SelectItem>
                </SelectContent>
              </Select>
              <Button
                type="button"
                disabled={jsonDraft.trim().length === 0 || busyAction != null}
                onClick={() => {
                  void runAction("import", () =>
                    importMcpConfig({ scope, json: jsonDraft }),
                  );
                }}
              >
                Import
              </Button>
            </div>
            <Textarea
              value={jsonDraft}
              className="min-h-36 font-mono"
              placeholder='{"mcpServers": {}}'
              onChange={(event) => setJsonDraft(event.target.value)}
            />
          </CardContent>
        </Card>
      </div>
    </PaneSurface>
  );
}

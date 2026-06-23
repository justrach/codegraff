import { describe, expect, test } from "bun:test";

const repoRoot = new URL("../../../", import.meta.url);

async function readRepoFile(path: string): Promise<string> {
  return Bun.file(new URL(path, repoRoot)).text();
}

function uniqueSorted(values: Iterable<string>): string[] {
  return Array.from(new Set(values)).sort();
}

function regexMatches(source: string, pattern: RegExp): string[] {
  return uniqueSorted(Array.from(source.matchAll(pattern), (match) => match[1]));
}

const qaOnlyHttpCommands = new Set([
  // In production this is served by the native Mer bridge. The QA browser mock
  // routes it through invokeCommand only so visual tests can run without Mer.
  "drain_pending_open",
]);

function clientHttpCommands(clientSource: string): string[] {
  return uniqueSorted(
    regexMatches(clientSource, /invokeCommand(?:<[^>]+>)?\(\s*["']([a-z0-9_]+)["']/g).filter(
      (command) => !qaOnlyHttpCommands.has(command),
    ),
  );
}

function directFetchCommands(source: string): string[] {
  return regexMatches(source, /fetch\(\s*["']\/api\/([a-z0-9_]+)["']/g);
}

function routeTableCommands(routesSource: string): string[] {
  return regexMatches(routesSource, /\.path\s*=\s*["']\/api\/([a-z0-9_]+)["']/g);
}

function runtimeHandleApiBody(runtimeSource: string): string {
  const start = runtimeSource.indexOf("pub fn handleApi(");
  const end = runtimeSource.indexOf("    fn jsonResponse", start);
  if (start < 0 || end < 0) {
    throw new Error("Runtime.handleApi body was not found");
  }
  return runtimeSource.slice(start, end);
}

function runtimeHandledCommands(runtimeSource: string): string[] {
  return regexMatches(
    runtimeHandleApiBody(runtimeSource),
    /std\.mem\.eql\(u8,\s*cmd,\s*["']([a-z0-9_]+)["']\)/g,
  );
}

describe("React↔Zig desktop route contract", () => {
  // These tests guard route existence only: they catch React↔routes.zig↔Runtime
  // drift before it becomes a 404. Endpoint behavior and payload semantics still
  // need separate tests for each API surface.
  test("all React HTTP API commands are present in routes.zig and Runtime.handleApi", async () => {
    const [clientSource, themeStoreSource, routesSource, runtimeSource] = await Promise.all([
      readRepoFile("src/services/desktop/client.ts"),
      readRepoFile("src/app/themeStore.ts"),
      readRepoFile("routes.zig"),
      readRepoFile("src-backend/runtime.zig"),
    ]);

    const reactCommands = uniqueSorted([
      ...clientHttpCommands(clientSource),
      ...directFetchCommands(themeStoreSource),
    ]);
    const routes = new Set(routeTableCommands(routesSource));
    const runtimeHandlers = new Set(runtimeHandledCommands(runtimeSource));

    const missingRoutes = reactCommands.filter((command) => !routes.has(command));
    const missingRuntimeHandlers = reactCommands.filter(
      (command) => !runtimeHandlers.has(command),
    );

    expect(missingRoutes).toEqual([]);
    expect(missingRuntimeHandlers).toEqual([]);
  });

  test("routes.zig and Runtime.handleApi stay symmetric", async () => {
    const [routesSource, runtimeSource] = await Promise.all([
      readRepoFile("routes.zig"),
      readRepoFile("src-backend/runtime.zig"),
    ]);

    const routes = routeTableCommands(routesSource);
    const runtimeHandlers = runtimeHandledCommands(runtimeSource);
    const routeSet = new Set(routes);
    const runtimeHandlerSet = new Set(runtimeHandlers);

    expect(routes.filter((command) => !runtimeHandlerSet.has(command))).toEqual([]);
    expect(runtimeHandlers.filter((command) => !routeSet.has(command))).toEqual([]);
  });
});

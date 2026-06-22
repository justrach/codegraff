import { afterEach, beforeEach, describe, expect, mock, test } from "bun:test";

mock.restore();

const realClientSpecifier = "./client.ts?real";
const {
  drainPendingOpen,
  openExternalUrl,
  openInTarget,
  openPathDefault,
  openPathForEdit,
  openPathInTarget,
  pickWorkspace,
  pickDirectory,
  readClipboardText,
  setWindowTitle,
  writeClipboardText,
} = (await import(realClientSpecifier)) as typeof import("./client");

type Invocation = { name: string; args: unknown };
type WindowOpenCall = {
  features?: string;
  target?: string;
  url?: string;
};

const originalWindow = Object.getOwnPropertyDescriptor(globalThis, "window");
const originalNavigator = Object.getOwnPropertyDescriptor(
  globalThis,
  "navigator",
);
const originalFetch = Object.getOwnPropertyDescriptor(globalThis, "fetch");

let fetchCalls: unknown[] = [];
let invocations: Invocation[] = [];
let openCalls: WindowOpenCall[] = [];

function restoreGlobal(name: "window" | "navigator" | "fetch", descriptor?: PropertyDescriptor) {
  if (descriptor != null) {
    Object.defineProperty(globalThis, name, descriptor);
  } else {
    delete (globalThis as Record<string, unknown>)[name];
  }
}

function installFetch() {
  fetchCalls = [];
  Object.defineProperty(globalThis, "fetch", {
    configurable: true,
    value: async (...args: unknown[]) => {
      fetchCalls.push(args);
      return new Response("{}", {
        headers: { "Content-Type": "application/json" },
        status: 200,
      });
    },
  });
}

function installWindow(
  invoke?: (name: string, args: unknown) => Promise<unknown>,
) {
  invocations = [];
  openCalls = [];
  const windowValue = {
    mer:
      invoke == null
        ? undefined
        : {
            invoke: async (name: string, args: unknown) => {
              invocations.push({ name, args });
              return invoke(name, args);
            },
          },
    open: (url?: string, target?: string, features?: string) => {
      openCalls.push({ features, target, url });
      return null;
    },
  };
  Object.defineProperty(globalThis, "window", {
    configurable: true,
    value: windowValue,
  });
}

function installClipboard(clipboard: Partial<Clipboard>) {
  Object.defineProperty(globalThis, "navigator", {
    configurable: true,
    value: { clipboard },
  });
}

async function expectRejects(promise: Promise<unknown>, message: string) {
  try {
    await promise;
  } catch (error) {
    expect(error).toBeInstanceOf(Error);
    expect((error as Error).message).toContain(message);
    return;
  }
  throw new Error("Expected promise to reject");
}

describe("desktop native bridge client", () => {
  beforeEach(() => {
    installFetch();
    installWindow();
    installClipboard({});
  });

  afterEach(() => {
    restoreGlobal("window", originalWindow);
    restoreGlobal("navigator", originalNavigator);
    restoreGlobal("fetch", originalFetch);
  });

  test("pickDirectory uses Mer dialog.pickDirectory without fetching", async () => {
    installWindow(async () => "/tmp/project");

    const selected = await pickDirectory("Choose workspace");

    expect(selected).toBe("/tmp/project");
    expect(invocations).toEqual([
      { name: "dialog.pickDirectory", args: { title: "Choose workspace" } },
    ]);
    expect(fetchCalls).toHaveLength(0);
  });

  test("pickWorkspace uses Mer dialog.pickDirectory without fetching", async () => {
    installWindow(async () => "/tmp/project");

    const selected = await pickWorkspace();

    expect(selected).toBe("/tmp/project");
    expect(invocations).toEqual([
      { name: "dialog.pickDirectory", args: { title: "Open project" } },
    ]);
    expect(fetchCalls).toHaveLength(0);
  });

  test("clipboard read/write use Mer before browser clipboard", async () => {
    let browserReadCount = 0;
    let browserWriteCount = 0;
    installClipboard({
      readText: async () => {
        browserReadCount += 1;
        return "browser";
      },
      writeText: async () => {
        browserWriteCount += 1;
      },
    });
    installWindow(async (name) => (name === "clipboard.read" ? "native" : null));

    expect(await readClipboardText()).toBe("native");
    await writeClipboardText("copied");

    expect(invocations).toEqual([
      { name: "clipboard.read", args: {} },
      { name: "clipboard.write", args: { text: "copied" } },
    ]);
    expect(browserReadCount).toBe(0);
    expect(browserWriteCount).toBe(0);
    expect(fetchCalls).toHaveLength(0);
  });

  test("clipboard falls back to browser clipboard only when Mer is absent", async () => {
    let written = "";
    installWindow();
    installClipboard({
      readText: async () => "browser",
      writeText: async (text) => {
        written = text;
      },
    });

    expect(await readClipboardText()).toBe("browser");
    await writeClipboardText("browser copy");

    expect(written).toBe("browser copy");
    expect(invocations).toEqual([]);
    expect(fetchCalls).toHaveLength(0);
  });

  test("openExternalUrl uses Mer, falls back only without Mer, and propagates Mer failures", async () => {
    installWindow(async () => null);
    await openExternalUrl("https://example.com");
    expect(invocations).toEqual([
      { name: "open.external", args: { url: "https://example.com" } },
    ]);
    expect(openCalls).toEqual([]);

    installWindow(async () => {
      throw new Error("native open failed");
    });
    await expectRejects(
      openExternalUrl("https://example.com/fail"),
      "native open failed",
    );
    expect(openCalls).toEqual([]);

    installWindow();
    await openExternalUrl("https://example.com/browser");
    expect(openCalls).toEqual([
      {
        features: "noopener,noreferrer",
        target: "_blank",
        url: "https://example.com/browser",
      },
    ]);
    expect(fetchCalls).toHaveLength(0);
  });

  test("path helpers call Mer open.path with concrete paths", async () => {
    installWindow(async () => null);

    await openPathDefault("/tmp/default.txt");
    await openPathForEdit("/tmp/edit.txt");
    await openInTarget("/Users/me/project", "file-manager");
    await openPathInTarget(
      "/Users/me/project/",
      "file-manager",
      "src/main.zig",
    );
    await openPathInTarget("/Users/me/project", "file-manager", "/tmp/abs.txt");

    expect(invocations).toEqual([
      { name: "open.path", args: { path: "/tmp/default.txt" } },
      { name: "open.path", args: { path: "/tmp/edit.txt" } },
      { name: "open.path", args: { path: "/Users/me/project" } },
      { name: "open.path", args: { path: "/Users/me/project/src/main.zig" } },
      { name: "open.path", args: { path: "/tmp/abs.txt" } },
    ]);
    expect(fetchCalls).toHaveLength(0);
  });

  test("setWindowTitle uses Mer window.setTitle when present", async () => {
    installWindow(async () => null);

    await setWindowTitle("Project - Codegraff");

    expect(invocations).toEqual([
      { name: "window.setTitle", args: { title: "Project - Codegraff" } },
    ]);
    expect(fetchCalls).toHaveLength(0);
  });

  test("unsupported open targets reject instead of pretending to succeed", async () => {
    installWindow(async () => null);

    await expectRejects(
      openInTarget("/Users/me/project", "cursor"),
      "not supported",
    );
    await expectRejects(
      openPathInTarget("/Users/me/project", "zed", "src/main.zig"),
      "not supported",
    );
    expect(invocations).toEqual([]);
  });

  test("drainPendingOpen tolerates the missing Mer command", async () => {
    installWindow(async () => {
      throw new Error("UnknownCommand");
    });

    expect(await drainPendingOpen()).toBe(null);
    expect(invocations).toEqual([{ name: "drainPendingOpen", args: {} }]);

    installWindow();
    expect(await drainPendingOpen()).toBe(null);
  });
});

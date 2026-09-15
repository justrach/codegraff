import { afterAll, beforeAll, expect, test } from "bun:test";
import { act, useCallback, useState } from "react";
import type { Attachment } from "../components/attachments/attachmentTypes";

let createRoot: typeof import("react-dom/client").createRoot;
let useClipboardPaste: typeof import("./useClipboardPaste").useClipboardPaste;
let useAttachments: typeof import("./useSession").useAttachments;
let sessionStore: typeof import("../app/sessionStore").sessionStore;
let getPromptDraftKey: typeof import("../app/sessionSnapshot").getPromptDraftKey;
let unregister: () => Promise<void>;
let save: (args: Record<string, unknown>) => Promise<string>;
const discarded: string[] = [];

beforeAll(async () => {
  const { GlobalRegistrator } = await import("@happy-dom/global-registrator");
  GlobalRegistrator.register();
  unregister = () => GlobalRegistrator.unregister();
  (globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;
  Object.defineProperty(window, "__TAURI_INTERNALS__", { value: {
    invoke: async (command: string, args: Record<string, unknown>) => {
      if (command === "save_pasted_image") return save(args);
      if (command === "discard_pasted_image") { discarded.push(args.path as string); return; }
      throw new Error(`Unexpected command ${command}`);
    },
  }, configurable: true });
  ({ createRoot } = await import("react-dom/client"));
  ({ useClipboardPaste } = await import("./useClipboardPaste"));
  ({ useAttachments } = await import("./useSession"));
  ({ sessionStore } = await import("../app/sessionStore"));
  ({ getPromptDraftKey } = await import("../app/sessionSnapshot"));
});
afterAll(async () => { await unregister(); });

function Composer({ scope }: { scope: string }) {
  const [attachments, setAttachments] = useState<Attachment[]>([]);
  const add = useCallback((items: Attachment[]) => {
    setAttachments(items.map((item) => ({ ...item, name: `${scope}:${item.name}` })));
  }, [scope]);
  const paste = useClipboardPaste(add);
  return <><textarea onPaste={paste} /><output>{attachments.map((item) => item.name).join()}</output></>;
}

function mount() {
  discarded.length = 0;
  const container = document.createElement("div");
  document.body.append(container);
  const root = createRoot(container);
  act(() => root.render(<Composer scope="first" />));
  return {
    container,
    switchScope: () => act(() => root.render(<Composer scope="second" />)),
    close: () => { act(() => root.unmount()); container.remove(); },
    paste: async () => {
      const event = new Event("paste", { bubbles: true, cancelable: true });
      Object.defineProperty(event, "clipboardData", { value: { items: [{
        kind: "file", type: "image/png",
        getAsFile: () => ({ arrayBuffer: async () => new Uint8Array([1, 2, 3]).buffer }),
      }] } });
      await act(async () => {
        container.querySelector("textarea")!.dispatchEvent(event);
        await Bun.sleep(1);
      });
      expect(event.defaultPrevented).toBe(true);
    },
  };
}

test("paste goes through the desktop client and transfers to the live draft", async () => {
  const composer = mount();
  save = async (args) => {
    expect(args).toEqual({ data: [1, 2, 3], ext: "png" });
    return "/clipboard/fixture.png";
  };
  try {
    await composer.paste();
    expect(composer.container.querySelector("output")!.textContent).toBe("first:fixture.png");
    expect(discarded).toEqual([]);
  } finally { composer.close(); }
});

test("an upload finishing after composer disposal releases its file", async () => {
  const composer = mount();
  let finish!: (path: string) => void;
  save = () => new Promise((resolve) => { finish = resolve; });
  await composer.paste();
  composer.close();
  await act(async () => { finish("/clipboard/late.png"); await Bun.sleep(1); });
  expect(discarded).toEqual(["/clipboard/late.png"]);
});

test("an upload cannot attach to a different conversation after navigation", async () => {
  const composer = mount();
  let finish!: (path: string) => void;
  save = () => new Promise((resolve) => { finish = resolve; });
  try {
    await composer.paste();
    composer.switchScope();
    await act(async () => { finish("/clipboard/old-scope.png"); await Bun.sleep(1); });
    expect(composer.container.querySelector("output")!.textContent).toBe("");
    expect(discarded).toEqual(["/clipboard/old-scope.png"]);
  } finally { composer.close(); }
});

function Tray({ conversationId }: { conversationId: string }) {
  const { attachments, removeAttachment } = useAttachments({ workspacePath: "/fixture", conversationId });
  return <>{attachments.map((item) => <button key={item.id}
    onClick={() => removeAttachment(item.id)}>{conversationId}</button>)}</>;
}

test("removing a chip releases the image only after the last draft tray drops it", async () => {
  discarded.length = 0;
  const keys = ["first", "second"].map((id) => getPromptDraftKey("/fixture", id)!);
  const item: Attachment = {
    id: "/clipboard/shared.png", path: "/clipboard/shared.png", name: "shared.png", ext: "png", kind: "image",
  };
  sessionStore.setState({ attachmentsByKey: Object.fromEntries(keys.map((key) => [key, [item]])) });
  const container = document.createElement("div");
  document.body.append(container);
  const root = createRoot(container);
  act(() => root.render(<><Tray conversationId="first" /><Tray conversationId="second" /></>));
  try {
    await act(async () => { container.querySelectorAll("button")[0]!.click(); });
    expect(discarded).toEqual([]);
    expect(container.querySelectorAll("button")).toHaveLength(1);
    await act(async () => { container.querySelector("button")!.click(); });
    expect(discarded).toEqual([item.path]);
    expect(container.querySelectorAll("button")).toHaveLength(0);
  } finally {
    act(() => root.unmount());
    container.remove();
    sessionStore.setState({ attachmentsByKey: {} });
  }
});

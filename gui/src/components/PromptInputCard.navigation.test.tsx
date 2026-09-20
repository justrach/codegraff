import { afterAll, beforeAll, expect, mock, test } from "bun:test";

import type { Attachment } from "./attachments/attachmentTypes";
import type { ChatBinding } from "@/services/desktop/types/contracts";

mock.module("@/hooks/useCommandAutocomplete", () => ({
  useCommandAutocomplete: () => ({
    activeIndex: 0,
    handleKeyDown: () => false,
    isOpen: false,
    items: [],
    pick: () => {},
    setActiveIndex: () => {},
  }),
}));

let createRoot: typeof import("react-dom/client").createRoot;
let flushSync: typeof import("react-dom").flushSync;
let PromptInputCard: typeof import("./PromptInputCard").PromptInputCard;
let usePromptDraft: typeof import("@/hooks/useSession").usePromptDraft;
let getPromptDraftKey: typeof import("@/app/sessionSnapshot").getPromptDraftKey;
let resetSessionStore: typeof import("@/app/sessionStore").resetSessionStore;
let sessionStore: typeof import("@/app/sessionStore").sessionStore;
let unregisterDom: () => Promise<void>;

beforeAll(async () => {
  const { GlobalRegistrator } = await import("@happy-dom/global-registrator");
  GlobalRegistrator.register();
  unregisterDom = () => GlobalRegistrator.unregister();
  (globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = false;
  Object.defineProperty(window, "__TAURI_INTERNALS__", {
    configurable: true,
    value: {
      invoke: async (command: string) => {
        if (command === "list_commands") return [];
        if (command === "image_thumbnail") return "";
        return null;
      },
    },
  });
  ({ createRoot } = await import("react-dom/client"));
  ({ flushSync } = await import("react-dom"));
  ({ PromptInputCard } = await import("./PromptInputCard"));
  ({ usePromptDraft } = await import("@/hooks/useSession"));
  ({ getPromptDraftKey } = await import("@/app/sessionSnapshot"));
  ({ resetSessionStore, sessionStore } = await import("@/app/sessionStore"));
});

afterAll(async () => {
  await unregisterDom();
});

const workspacePath = "/workspace/history-tests";

function getBinding(
  scope: string,
  bindings?: Record<string, ChatBinding>,
): ChatBinding {
  return bindings?.[scope] ?? { conversationId: scope, workspacePath };
}

function ComposerHarness({
  bindings,
  histories,
  scope,
}: {
  bindings?: Record<string, ChatBinding>;
  histories: Record<string, string[]>;
  scope: string;
}) {
  const binding = getBinding(scope, bindings);
  const { promptDraft, setPromptDraft } = usePromptDraft(binding);

  return (
    <PromptInputCard
      binding={binding}
      canCompose
      isPlanningMode={false}
      isRequestActive={false}
      isSendingPrompt={false}
      isUltraMode={false}
      onCommandSelect={() => {}}
      promptDraft={promptDraft}
      promptHistory={histories[scope] ?? []}
      promptSettings={null}
      setPlanningMode={() => {}}
      setPromptDraft={setPromptDraft}
      setUltraMode={() => {}}
      stopPrompt={async () => {}}
      submitPrompt={async () => {}}
      updatePromptSettings={async () => {}}
      workspacePath={binding.workspacePath}
    />
  );
}

function mountComposer(input: {
  bindings?: Record<string, ChatBinding>;
  histories: Record<string, string[]>;
  initialAttachments?: Record<string, Attachment[]>;
  initialDrafts: Record<string, string>;
  scope: string;
}) {
  resetSessionStore();
  for (const [conversationId, draft] of Object.entries(input.initialDrafts)) {
    const binding = getBinding(conversationId, input.bindings);
    const key = getPromptDraftKey(
      binding.workspacePath,
      binding.conversationId,
    )!;
    sessionStore.getState().setPromptDraftValue(key, draft);
  }
  for (const [conversationId, attachments] of Object.entries(
    input.initialAttachments ?? {},
  )) {
    const binding = getBinding(conversationId, input.bindings);
    const key = getPromptDraftKey(
      binding.workspacePath,
      binding.conversationId,
    )!;
    sessionStore.getState().addAttachments(key, attachments);
  }
  const container = document.createElement("div");
  document.body.append(container);
  const root = createRoot(container);
  let scope = input.scope;

  const render = () => {
    flushSync(() => {
      root.render(
        <ComposerHarness
          bindings={input.bindings}
          histories={input.histories}
          scope={scope}
        />,
      );
    });
  };
  render();

  return {
    container,
    arrow(
      key: "ArrowUp" | "ArrowDown",
      caret = container.querySelector("textarea")!.value.length,
    ) {
      const textarea = container.querySelector("textarea")!;
      textarea.setSelectionRange(caret, caret);
      flushSync(() => {
        textarea.dispatchEvent(
          new KeyboardEvent("keydown", {
            bubbles: true,
            cancelable: true,
            key,
          }),
        );
      });
    },
    close() {
      flushSync(() => root.unmount());
      container.remove();
      resetSessionStore();
    },
    switchScope(nextScope: string) {
      scope = nextScope;
      render();
    },
    textareaValue() {
      return container.querySelector("textarea")!.value;
    },
  };
}

function image(path: string): Attachment {
  return {
    ext: "png",
    id: path,
    kind: "image",
    name: path.split("/").at(-1)!,
    path,
  };
}

function attachmentTitles(container: HTMLElement) {
  return Array.from(container.querySelectorAll<HTMLElement>("[title]"))
    .map((element) => element.title)
    .filter((title) => title.endsWith(".png"));
}

test("recalled multiline prompts keep navigating instead of trapping ArrowUp", () => {
  const composer = mountComposer({
    histories: {
      chat: ["older prompt", "newest prompt\nwith a second line"],
    },
    initialDrafts: { chat: "draft" },
    scope: "chat",
  });

  try {
    composer.arrow("ArrowUp");
    expect(composer.textareaValue()).toBe("newest prompt\nwith a second line");

    composer.arrow("ArrowUp");
    expect(composer.textareaValue()).toBe("older prompt");
  } finally {
    composer.close();
  }
});

test("live multiline drafts keep ArrowUp in the textarea below the first line", () => {
  const composer = mountComposer({
    histories: { chat: ["older prompt"] },
    initialDrafts: { chat: "first line\nsecond line" },
    scope: "chat",
  });

  try {
    composer.arrow("ArrowUp");
    expect(composer.textareaValue()).toBe("first line\nsecond line");

    composer.arrow("ArrowUp", 0);
    expect(composer.textareaValue()).toBe("older prompt");
  } finally {
    composer.close();
  }
});

test("equal-length chat switches cannot restore another chat's draft or attachments", () => {
  const firstAttachment = image("/images/first-live.png");
  const secondAttachment = image("/images/second-live.png");
  const composer = mountComposer({
    histories: {
      first: ["first old", "first new"],
      second: ["second old", "second new"],
    },
    initialAttachments: {
      first: [firstAttachment],
      second: [secondAttachment],
    },
    initialDrafts: {
      first: "first draft",
      second: "second draft",
    },
    scope: "first",
  });

  try {
    composer.arrow("ArrowUp");
    expect(composer.textareaValue()).toBe("first new");

    composer.switchScope("second");
    expect(composer.textareaValue()).toBe("second draft");
    expect(attachmentTitles(composer.container)).toEqual([
      secondAttachment.path,
    ]);

    composer.arrow("ArrowDown");
    expect(composer.textareaValue()).toBe("second draft");
    expect(attachmentTitles(composer.container)).toEqual([
      secondAttachment.path,
    ]);

    composer.arrow("ArrowUp");
    expect(composer.textareaValue()).toBe("second new");
  } finally {
    composer.close();
  }
});

test("scope round trips cannot revive an earlier cursor or attachment snapshot", () => {
  const firstAttachment = image("/images/first-live.png");
  const composer = mountComposer({
    histories: {
      first: ["first old", "first new"],
      second: ["second old", "second new"],
    },
    initialAttachments: { first: [firstAttachment] },
    initialDrafts: {
      first: "first draft",
      second: "second draft",
    },
    scope: "first",
  });

  try {
    composer.arrow("ArrowUp");
    expect(composer.textareaValue()).toBe("first new");
    expect(attachmentTitles(composer.container)).toEqual([]);

    composer.switchScope("second");
    composer.switchScope("first");
    composer.arrow("ArrowDown");

    expect(composer.textareaValue()).toBe("first new");
    expect(attachmentTitles(composer.container)).toEqual([]);
  } finally {
    composer.close();
  }
});

test("delimiter-like scope values keep attachments isolated", () => {
  const firstAttachment = image("/images/workspace-first.png");
  const secondAttachment = image("/images/workspace-second.png");
  const composer = mountComposer({
    bindings: {
      first: {
        conversationId: "b",
        workspacePath: "/workspace/a::chat",
      },
      second: {
        conversationId: "chat::b",
        workspacePath: "/workspace/a",
      },
    },
    histories: { first: [], second: [] },
    initialAttachments: {
      first: [firstAttachment],
      second: [secondAttachment],
    },
    initialDrafts: {
      first: "first workspace draft",
      second: "second workspace draft",
    },
    scope: "first",
  });

  try {
    expect(attachmentTitles(composer.container)).toEqual([
      firstAttachment.path,
    ]);

    composer.switchScope("second");
    expect(composer.textareaValue()).toBe("second workspace draft");
    expect(attachmentTitles(composer.container)).toEqual([
      secondAttachment.path,
    ]);
  } finally {
    composer.close();
  }
});

test("each recalled prompt replaces attachments and exiting restores only the live draft", () => {
  const live = image("/images/live.png");
  const newest = image("/images/newest.png");
  const older = [
    image("/images/older-a.png"),
    image("/images/older-b.png"),
    image("/images/older-c.png"),
  ];
  const composer = mountComposer({
    histories: {
      chat: [
        `older\n\nAttached files:\n${older.map((item) => `@[${item.path}]`).join("\n")}`,
        `newest\n\nAttached files:\n@[${newest.path}]`,
      ],
    },
    initialAttachments: { chat: [live] },
    initialDrafts: { chat: "live draft" },
    scope: "chat",
  });

  const key = getPromptDraftKey(workspacePath, "chat")!;
  const replacementNotifications: string[][] = [];
  let unsubscribe: (() => void) | null = sessionStore.subscribe(
    (current, prior) => {
      if (current.attachmentsByKey[key] !== prior.attachmentsByKey[key]) {
        replacementNotifications.push(
          (current.attachmentsByKey[key] ?? []).map((item) => item.path),
        );
      }
    },
  );

  try {
    composer.arrow("ArrowUp");
    unsubscribe();
    unsubscribe = null;
    expect(composer.textareaValue()).toBe("newest");
    expect(attachmentTitles(composer.container)).toEqual([newest.path]);
    expect(replacementNotifications).toEqual([[newest.path]]);

    composer.arrow("ArrowUp");
    expect(composer.textareaValue()).toBe("older");
    expect(attachmentTitles(composer.container)).toEqual(
      older.map((item) => item.path),
    );

    composer.arrow("ArrowDown");
    expect(attachmentTitles(composer.container)).toEqual([newest.path]);

    composer.arrow("ArrowDown");
    expect(composer.textareaValue()).toBe("live draft");
    expect(attachmentTitles(composer.container)).toEqual([live.path]);
  } finally {
    unsubscribe?.();
    composer.close();
  }
});

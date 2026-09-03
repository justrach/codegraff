import { afterAll, beforeAll, expect, mock, test } from "bun:test";
import { act } from "react";

import { CHAT_BODY_TONE_CLASS } from "./constants/chatStyles";

// #729 asked for the final rendered assistant-message anchor, not only the
// matcher: the component the assistant row mounts (ChatMessageRow renders an
// assistant message as <article><ChatMarkdown/></article>), clicked the way a
// user clicks it, with the argument that reaches the open-link path captured
// verbatim. ChatMarkdown rather than ChatMessageRow because module mocks are
// process-wide under bun test and an earlier file may leave the desktop client
// as a partial stub; the row imports an export such a stub cannot gain.
const ISSUE_URL = "https://github.com/justrach/codegraff/issues/728";

const opened: string[] = [];

mock.module("./utils/chatOpen", () => ({
  openUrlFromChat: (url: string) => {
    opened.push(url);
  },
  openFilePathFromChat: async () => {},
}));

let unregisterDom: (() => Promise<void>) | null = null;
let createRoot: typeof import("react-dom/client").createRoot;
let ChatMarkdown: typeof import("./ChatMarkdown").ChatMarkdown;

beforeAll(async () => {
  // The DOM is registered before react-dom/client and the component are
  // loaded, so both see a real document from the start.
  const { GlobalRegistrator } = await import("@happy-dom/global-registrator");
  GlobalRegistrator.register();
  unregisterDom = () => GlobalRegistrator.unregister();
  // happy-dom leaves document.compatMode undefined; KaTeX (pulled in by the
  // renderer) reads it at load and warns about quirks mode unless it says
  // standards mode.
  Object.defineProperty(document, "compatMode", { value: "CSS1Compat", configurable: true });
  (globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;
  ({ createRoot } = await import("react-dom/client"));
  ({ ChatMarkdown } = await import("./ChatMarkdown"));
});

afterAll(async () => {
  await unregisterDom?.();
});

// Mounts the assistant message body with the props ChatMessageRow passes it.
function mountAssistantMessage(text: string) {
  const container = document.createElement("div");
  document.body.appendChild(container);
  const root = createRoot(container);
  act(() => {
    root.render(
      <ChatMarkdown
        text={text}
        className={`cg-stream-in ${CHAT_BODY_TONE_CLASS}`}
        workspacePath={null}
      />,
    );
  });
  return {
    container,
    unmount: () => {
      act(() => root.unmount());
      container.remove();
    },
  };
}

test("assistant message: a bold-wrapped bare URL renders bold, and both the anchor text and the open target are exactly the URL", () => {
  opened.length = 0;
  const { container, unmount } = mountAssistantMessage(`**${ISSUE_URL}**`);
  try {
    const anchor = container.querySelector("button");
    expect(anchor).not.toBeNull();
    // Neither delimiter pair survives as text: the whole message reads as the URL.
    expect(anchor!.textContent).toBe(ISSUE_URL);
    expect(container.textContent).toBe(ISSUE_URL);
    expect(anchor!.getAttribute("title")).toBe(ISSUE_URL);
    // The emphasis renders as bold around the anchor.
    expect(anchor!.closest(".font-medium")).not.toBeNull();

    // Cmd-click and a plain click both hand the open-link path exactly the URL.
    act(() => {
      anchor!.dispatchEvent(
        new MouseEvent("click", { bubbles: true, cancelable: true, metaKey: true }),
      );
    });
    act(() => {
      anchor!.click();
    });
    expect(opened).toEqual([ISSUE_URL, ISSUE_URL]);
  } finally {
    unmount();
  }
});

test("assistant message: a bold-wrapped URL inside a sentence keeps punctuation and parentheses out of the target", () => {
  opened.length = 0;
  const { container, unmount } = mountAssistantMessage(
    `Filed as **${ISSUE_URL}** (P0, see **${ISSUE_URL}**).`,
  );
  try {
    const anchors = Array.from(container.querySelectorAll("button"));
    expect(anchors.map((anchor) => anchor.textContent)).toEqual([ISSUE_URL, ISSUE_URL]);
    expect(container.textContent).toBe(`Filed as ${ISSUE_URL} (P0, see ${ISSUE_URL}).`);
    for (const anchor of anchors) {
      act(() => {
        anchor.click();
      });
    }
    expect(opened).toEqual([ISSUE_URL, ISSUE_URL]);
  } finally {
    unmount();
  }
});

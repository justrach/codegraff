import {
  afterAll,
  beforeAll,
  beforeEach,
  describe,
  expect,
  mock,
  test,
} from "bun:test";
import type { ReactNode } from "react";
import ReactDOM from "react-dom";

import type { TranscriptMessage } from "@/services/desktop/types/contracts";

const { flushSync } = ReactDOM;

let unregisterDom: (() => Promise<void>) | null = null;
let createRoot: typeof import("react-dom/client").createRoot;
let ChatMarkdownMessage: typeof import("./ChatMarkdownMessage").ChatMarkdownMessage;
let ChatMessageRow: typeof import("./ChatMessageRow").ChatMessageRow;
let ChatTranscriptMessage: typeof import("./ChatTranscriptMessage").ChatTranscriptMessage;

beforeAll(async () => {
  const { GlobalRegistrator } = await import("@happy-dom/global-registrator");
  GlobalRegistrator.register();
  unregisterDom = () => GlobalRegistrator.unregister();
  Object.defineProperty(document, "compatMode", {
    value: "CSS1Compat",
    configurable: true,
  });
  ({ createRoot } = await import("react-dom/client"));
  ({ ChatMarkdownMessage } = await import("./ChatMarkdownMessage"));
  ({ ChatMessageRow } = await import("./ChatMessageRow"));
  ({ ChatTranscriptMessage } = await import("./ChatTranscriptMessage"));
});

afterAll(async () => {
  await unregisterDom?.();
});

beforeEach(() => {
  document.body.replaceChildren();
  Object.defineProperty(navigator, "clipboard", {
    value: undefined,
    configurable: true,
  });
});

function mount(node: ReactNode) {
  const container = document.createElement("div");
  document.body.appendChild(container);
  const root = createRoot(container);
  flushSync(() => {
    root.render(node);
  });

  return {
    container,
    rerender: (nextNode: ReactNode) => {
      flushSync(() => {
        root.render(nextNode);
      });
    },
    unmount: () => {
      flushSync(() => root.unmount());
      container.remove();
    },
  };
}

function contentMessage(
  kind: "user" | "assistant" | "reasoning",
  text: string,
): Extract<TranscriptMessage, { kind: "user" | "assistant" | "reasoning" }> {
  return {
    kind,
    id: `${kind}-1`,
    requestId: "request-1",
    text,
  };
}

function mountMarkdownMessage(text: string, copyText?: string) {
  return mount(
    <ChatMarkdownMessage
      copyText={copyText}
      text={text}
      toneClassName="text-foreground"
      workspacePath={null}
    />,
  );
}

function setClipboard(writeText: (value: string) => Promise<void>) {
  Object.defineProperty(navigator, "clipboard", {
    value: { writeText },
    configurable: true,
  });
}

async function flushUpdates(delayMs = 10) {
  await new Promise((resolve) => window.setTimeout(resolve, delayMs));
}

describe("chat response copy dispatch", () => {
  test("the thread adds the copy action to user and assistant messages", () => {
    const messages: Array<[TranscriptMessage, boolean]> = [
      [contentMessage("assistant", "Answer"), true],
      [contentMessage("user", "Question"), true],
      [contentMessage("reasoning", "Private reasoning"), false],
      [
        {
          kind: "status",
          id: "status-1",
          requestId: "request-1",
          title: "Working",
          subtitle: "Still working",
          category: "info",
        },
        false,
      ],
      [
        {
          kind: "tool_start",
          id: "tool-1",
          requestId: "request-1",
          name: "shell",
          callId: "call-1",
          detail: {
            kind: "shell",
            command: "pwd",
            cwd: null,
            description: null,
          },
        },
        false,
      ],
    ];

    for (const [message, shouldCopy] of messages) {
      const row = mount(
        <ChatTranscriptMessage message={message} workspacePath={null} />,
      );
      try {
        expect(
          row.container.querySelector('button[aria-label="Copy response"]') !=
            null,
        ).toBe(shouldCopy);
      } finally {
        row.unmount();
      }
    }
  });

  test("an assistant row streamed in place copies the latest response only", async () => {
    const writeText = mock(async () => {});
    setClipboard(writeText);
    const row = mount(
      <ChatMessageRow
        message={contentMessage("assistant", "")}
        workspacePath={null}
      />,
    );

    try {
      expect(row.container.querySelector("button")).toBeNull();

      row.rerender(
        <ChatMessageRow
          message={contentMessage("assistant", "Partial")}
          workspacePath={null}
        />,
      );
      expect(
        row.container.querySelector('button[aria-label="Copy response"]'),
      ).not.toBeNull();

      const finalText = "Final **answer**\n\n```ts\nconst value = 1;\n```";
      row.rerender(
        <ChatMessageRow
          message={contentMessage("assistant", finalText)}
          workspacePath={null}
        />,
      );
      const button = row.container.querySelector<HTMLButtonElement>(
        'button[aria-label="Copy response"]',
      );
      expect(button).not.toBeNull();

      button!.click();
      await flushUpdates();

      expect(writeText).toHaveBeenCalledTimes(1);
      expect(writeText).toHaveBeenCalledWith(finalText);
    } finally {
      row.unmount();
    }
  });
});

describe("assistant response copy behavior", () => {
  test("copies the exact raw output, including Markdown, whitespace, and Unicode", async () => {
    const text = "## Result\n\n```ts\nconst café = \"☕\";\n```\n\nDone.  ";
    const writeText = mock(async () => {});
    setClipboard(writeText);
    const { container, unmount } = mountMarkdownMessage(text, text);

    try {
      const button = container.querySelector<HTMLButtonElement>(
        'button[aria-label="Copy response"]',
      );
      expect(button).not.toBeNull();

      button!.click();
      await flushUpdates();

      expect(writeText).toHaveBeenCalledTimes(1);
      expect(writeText).toHaveBeenCalledWith(text);
      expect(button!.getAttribute("aria-label")).toBe("Copied");
      expect(button!.textContent).toBe("Copied");
    } finally {
      unmount();
    }
  });

  test("does not add a copy action without an assistant copy payload", () => {
    const { container, unmount } = mountMarkdownMessage("Private reasoning text");
    try {
      expect(container.querySelector('button[aria-label="Copy response"]')).toBeNull();
    } finally {
      unmount();
    }
  });

  test("adds the action during streaming and copies whitespace exactly", async () => {
    const writeText = mock(async () => {});
    setClipboard(writeText);
    const message = mountMarkdownMessage("", "");

    try {
      expect(message.container.querySelector("button")).toBeNull();

      message.rerender(
        <ChatMarkdownMessage
          copyText={" \n\t "}
          text={" \n\t "}
          toneClassName="text-foreground"
          workspacePath={null}
        />,
      );

      const button = message.container.querySelector<HTMLButtonElement>(
        'button[aria-label="Copy response"]',
      );
      expect(button).not.toBeNull();
      button!.click();
      await flushUpdates();
      expect(writeText).toHaveBeenCalledWith(" \n\t ");
    } finally {
      message.unmount();
    }
  });

  test("keeps the default label when clipboard access is unavailable or rejects", async () => {
    const unavailable = mountMarkdownMessage("Hello", "Hello");
    try {
      const button = unavailable.container.querySelector<HTMLButtonElement>("button");
      expect(button).not.toBeNull();
      button!.click();
      await flushUpdates();
      expect(button!.getAttribute("aria-label")).toBe("Copy response");
    } finally {
      unavailable.unmount();
    }

    setClipboard(async () => {
      throw new Error("clipboard denied");
    });
    const rejected = mountMarkdownMessage("Hello again", "Hello again");
    try {
      const button = rejected.container.querySelector<HTMLButtonElement>("button");
      expect(button).not.toBeNull();
      button!.click();
      await flushUpdates();
      expect(button!.getAttribute("aria-label")).toBe("Copy response");
      expect(button!.textContent).toBe("Copy response");
    } finally {
      rejected.unmount();
    }
  });

  test("returns copied feedback to the default label after the reset delay", async () => {
    setClipboard(async () => {});
    const { container, unmount } = mountMarkdownMessage("Reset me", "Reset me");

    try {
      const button = container.querySelector<HTMLButtonElement>("button");
      expect(button).not.toBeNull();
      button!.click();
      await flushUpdates();
      expect(button!.getAttribute("aria-label")).toBe("Copied");

      await flushUpdates(1_250);

      expect(button!.getAttribute("aria-label")).toBe("Copy response");
      expect(button!.textContent).toBe("Copy response");
    } finally {
      unmount();
    }
  });
});

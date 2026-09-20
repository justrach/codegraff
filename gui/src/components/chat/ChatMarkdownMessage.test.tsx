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

const { flushSync } = ReactDOM;

let unregisterDom: (() => Promise<void>) | null = null;
let createRoot: typeof import("react-dom/client").createRoot;
let ChatMarkdownMessage: typeof import("./ChatMarkdownMessage").ChatMarkdownMessage;

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

function mountMessage(text: string, copyText?: string) {
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

async function flushUpdates(delayMs = 0) {
  await new Promise((resolve) => window.setTimeout(resolve, delayMs));
}

async function click(button: HTMLButtonElement) {
  button.click();
  await flushUpdates();
}

describe("assistant response copy action", () => {
  test("copies the exact raw output, including Markdown, whitespace, and Unicode", async () => {
    const text = "## Result\n\n```ts\nconst café = \"☕\";\n```\n\nDone.  ";
    const writeText = mock(async () => {});
    setClipboard(writeText);
    const { container, unmount } = mountMessage(text, text);

    try {
      const button = container.querySelector<HTMLButtonElement>(
        'button[aria-label="Copy response"]',
      );
      expect(button).not.toBeNull();

      await click(button!);

      expect(writeText).toHaveBeenCalledTimes(1);
      expect(writeText).toHaveBeenCalledWith(text);
      expect(button!.getAttribute("aria-label")).toBe("Copied");
      expect(button!.textContent).toBe("Copied");
    } finally {
      unmount();
    }
  });

  test("does not add a copy action when no assistant copy payload is provided", () => {
    const { container, unmount } = mountMessage("Private reasoning text");
    try {
      expect(container.querySelector('button[aria-label="Copy response"]')).toBeNull();
    } finally {
      unmount();
    }
  });

  test("adds the action during streaming and copies the latest output exactly", async () => {
    const writeText = mock(async () => {});
    setClipboard(writeText);
    const message = mountMessage("", "");

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
      await click(button!);
      expect(writeText).toHaveBeenCalledWith(" \n\t ");
    } finally {
      message.unmount();
    }
  });

  test("keeps the default label when clipboard access is unavailable or rejects", async () => {
    const unavailable = mountMessage("Hello", "Hello");
    try {
      const button = unavailable.container.querySelector<HTMLButtonElement>("button");
      expect(button).not.toBeNull();
      await click(button!);
      expect(button!.getAttribute("aria-label")).toBe("Copy response");
    } finally {
      unavailable.unmount();
    }

    setClipboard(async () => {
      throw new Error("clipboard denied");
    });
    const rejected = mountMessage("Hello again", "Hello again");
    try {
      const button = rejected.container.querySelector<HTMLButtonElement>("button");
      expect(button).not.toBeNull();
      await click(button!);
      expect(button!.getAttribute("aria-label")).toBe("Copy response");
      expect(button!.textContent).toBe("Copy response");
    } finally {
      rejected.unmount();
    }
  });

  test("returns copied feedback to the default label after the reset delay", async () => {
    setClipboard(async () => {});
    const { container, unmount } = mountMessage("Reset me", "Reset me");

    try {
      const button = container.querySelector<HTMLButtonElement>("button");
      expect(button).not.toBeNull();
      await click(button!);
      expect(button!.getAttribute("aria-label")).toBe("Copied");

      await flushUpdates(1_250);

      expect(button!.getAttribute("aria-label")).toBe("Copy response");
      expect(button!.textContent).toBe("Copy response");
    } finally {
      unmount();
    }
  });
});

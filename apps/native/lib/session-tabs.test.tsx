import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import SessionTabs from "../components/site/SessionTabs";

const chats = [
  { id: 1, title: "Review thread" },
  { id: 2, title: "Idle notes" },
];

function markup(busyIds: ReadonlySet<number>, unreadIds?: ReadonlySet<number>) {
  return renderToStaticMarkup(
    <SessionTabs
      chats={chats}
      activeId={1}
      busyIds={busyIds}
      unreadIds={unreadIds}
      agentsOpen={false}
      focusChat={() => undefined}
      closeChat={() => undefined}
    />,
  );
}

function activationInner(html: string, title: string) {
  const buttons = html.match(/<button\b[\s\S]*?<\/button>/g) ?? [];
  return buttons.find(button => button.includes("aria-pressed") && button.includes(title)) ?? "";
}

test("working status and title share the full-height tab activation control", () => {
  const html = markup(new Set([1]));
  const activate = activationInner(html, "Review thread");
  expect(activate).toContain('aria-label="Working"');
  expect(activate).toContain("Review thread");
  expect(activate).toContain("pl-2.5");
  expect(activate).toContain("h-full");
  expect(activate).not.toContain('aria-label="Close tab"');
  expect(html).toContain('aria-label="Close tab"');
  expect(html.indexOf('aria-label="Working"')).toBeLessThan(html.indexOf('aria-label="Close tab"'));
});

test("unread marker sits inside the same activation control as the title", () => {
  const html = markup(new Set(), new Set([2]));
  const activate = activationInner(html, "Idle notes");
  expect(activate).toContain('aria-label="Unread response"');
  expect(activate).toContain("Idle notes");
  expect(activate).not.toContain('aria-label="Close tab"');
});

import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import Markdown from "../components/primitives/Markdown";

test("the block caret is only on a live reply", () => {
  const live = renderToStaticMarkup(<Markdown text="Checking the motion lifecycle" streaming />);
  const done = renderToStaticMarkup(<Markdown text="Checking the motion lifecycle" />);
  expect(live).toContain("--streamdown-caret");
  expect(done).not.toContain("--streamdown-caret");
});

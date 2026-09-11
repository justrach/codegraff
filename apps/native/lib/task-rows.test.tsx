import { describe, expect, it } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import TaskRows, { type TaskItem } from "../components/primitives/TaskRows";

const statuses = ["pending", "in_progress", "completed", "failed"] as const;
const statusLabels = {
  pending: "Pending",
  in_progress: "In progress",
  completed: "Completed",
  failed: "Failed",
};
const chevron = 'd="M6 9l6 6 6-6"';
const detailTransition = "transition-[grid-template-rows,opacity]";
const detailSpacing = "mb-2.5 grid grid-cols-[24px_1fr]";

function render(variant: string, items: TaskItem[]) {
  return renderToStaticMarkup(<TaskRows variant={variant} items={items} />);
}

function expectNoDisclosure(markup: string) {
  expect(markup).not.toContain("<button");
  expect(markup).not.toContain('role="button"');
  expect(markup).not.toContain("tabindex=");
  expect(markup).not.toContain("aria-expanded=");
  expect(markup).not.toContain(chevron);
  expect(markup).not.toContain(detailTransition);
  expect(markup).not.toContain(detailSpacing);
  expect(markup).not.toContain("grid-template-rows:");
}

// Static rendering checks the disclosure control and its content together,
// without depending on the demo timers or a browser DOM.
describe("TaskRows disclosure (#826)", () => {
  for (const variant of ["List", "Capsules"]) {
    describe(variant, () => {
      for (const status of statuses) {
        for (const details of [undefined, []] as const) {
          it(`${status} has no disclosure when details are ${details === undefined ? "omitted" : "empty"}`, () => {
            const item: TaskItem = {
              key: "index",
              label: "Review task",
              status,
              amount: "3 records",
              ...(details === undefined ? {} : { details: [] }),
            };
            const markup = render(variant, [item]);

            expect(markup).toContain("Review task");
            expect(markup).toContain("3 records");
            expect(markup).toContain(statusLabels[status]);
            expectNoDisclosure(markup);
          });
        }

        it(`${status} preserves the collapsed disclosure and actual details`, () => {
          const markup = render(variant, [{
            key: "with-details",
            label: "Review task",
            status,
            details: [
              { label: "Matched records", meta: "3/3" },
              { label: "Checked contacts" },
            ],
          }]);

          expect(markup.match(/<button\b/g)).toHaveLength(1);
          expect(markup).toMatch(/<button\b[^>]*type="button"[^>]*aria-expanded="false"/);
          expect(markup).toContain(statusLabels[status]);
          expect(markup).toContain(chevron);
          expect(markup).toContain(detailTransition);
          expect(markup).toContain("grid-template-rows:0fr");
          expect(markup).toContain("Matched records");
          expect(markup).toContain("3/3");
          expect(markup).toContain("Checked contacts");
        });
      }

      it("only exposes disclosure for detail-bearing rows in a mixed list", () => {
        const markup = render(variant, [
          { key: "missing", label: "No details supplied", status: "pending" },
          {
            key: "populated", label: "Expandable task", status: "in_progress",
            details: [{ label: "Actual detail", meta: "1/2" }],
          },
          { key: "empty", label: "Empty details supplied", status: "completed", details: [] },
          { key: "failed", label: "Failed without details", status: "failed" },
        ]);

        const buttons = markup.match(/<button\b[^>]*>[\s\S]*?<\/button>/g) ?? [];
        expect(buttons).toHaveLength(1);
        expect(buttons[0]).toContain("Expandable task");
        expect(buttons[0]).toContain('aria-expanded="false"');
        expect(buttons[0]).not.toContain("No details supplied");
        expect(buttons[0]).not.toContain("Empty details supplied");
        expect(buttons[0]).not.toContain("Failed without details");
        expect(markup.split("aria-expanded=")).toHaveLength(2);
        expect(markup.split(chevron)).toHaveLength(2);
        expect(markup.split(detailTransition)).toHaveLength(2);
        expect(markup.split(detailSpacing)).toHaveLength(2);
        expect(markup).toContain("Actual detail");
        for (const label of ["No details supplied", "Empty details supplied", "Failed without details"]) {
          expect(markup).toContain(label);
        }
      });
    });
  }
});

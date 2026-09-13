import { test, expect } from "@playwright/test";

const image = "@[/tmp/graff-native-attachments/queued-image.png]";
const row = '[data-queued-prompt="2"]';
test.beforeEach(async ({ page }) => {
  await page.route("**/api/attach?name=*", route => route.fulfill({
    contentType: "image/png",
    body: Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aZ1sAAAAASUVORK5CYII=", "base64"),
  }));
  await page.goto("/visual-tests/queue");
  await page.getByRole("button", { name: "Start fixture" }).click();
});

test("editing a non-head message pauses completion and sends the saved multiline text", async ({ page }) => {
  const queued = page.locator(row);
  await expect(queued.locator("img")).toHaveJSProperty("naturalWidth", 1);
  await expect(queued).toContainText("queued-image.png");
  await expect(queued).not.toContainText("graff-native-attachments");
  await expect(page.locator("main").getByRole("alert")).toHaveText("Could not interrupt the current turn");
  await queued.getByRole("button", { name: "Edit queued message" }).click();
  const editor = queued.getByRole("textbox", { name: "Edit queued message" });
  await expect(editor).toBeFocused();
  await expect(editor).toHaveValue(`Look at this\n${image}`);
  await editor.fill(`Revised explanation\n${image}`);
  await page.getByRole("button", { name: "Finish turn" }).click();
  await expect(page.getByLabel("Sent messages")).toHaveText("[]");
  await expect(queued.getByRole("button", { name: "Save queued message" })).toBeVisible();
  await expect(page.getByRole("button", { name: "Steer now" })).toBeDisabled();
  await queued.getByRole("button", { name: "Save queued message" }).click();
  await expect(page.getByLabel("Sent messages")).toHaveText(JSON.stringify(["First follow-up"]));
  await page.getByRole("button", { name: "Finish turn" }).click();
  await expect(page.getByLabel("Sent messages")).toHaveText(JSON.stringify(["First follow-up", `Revised explanation\n${image}`]));
  await expect(page.getByLabel("Queue state")).toHaveText("{}");
});

test("Escape resumes the original text and blank Save removes an entry", async ({ page }) => {
  await page.locator(row).getByRole("button", { name: "Edit queued message" }).click();
  await page.getByRole("textbox", { name: "Edit queued message" }).fill("Discard this draft");
  await page.getByRole("button", { name: "Finish turn" }).click();
  await page.getByRole("textbox", { name: "Edit queued message" }).press("Escape");
  await expect(page.getByLabel("Sent messages")).toHaveText(JSON.stringify(["First follow-up"]));
  await expect(page.locator(row)).toContainText("Look at this");
  await page.locator(row).getByRole("button", { name: "Edit queued message" }).click();
  await page.getByRole("textbox", { name: "Edit queued message" }).fill("   ");
  await page.getByRole("button", { name: "Finish turn" }).click();
  await page.getByRole("button", { name: "Save queued message" }).click();
  await expect(page.getByLabel("Queue state")).toHaveText("{}");
  await expect(page.getByLabel("Sent messages")).toHaveText(JSON.stringify(["First follow-up"]));
});

test("another editor cannot discard a draft and closing a chat clears all queued work", async ({ page }) => {
  await page.locator(row).getByRole("button", { name: "Edit queued message" }).click();
  await expect(page.locator('[data-queued-prompt="1"]').getByRole("button", { name: "Edit queued message" })).toBeDisabled();
  await page.getByRole("button", { name: "Finish turn" }).click();
  await page.getByRole("button", { name: "Cancel edit" }).click();
  await expect(page.getByLabel("Sent messages")).toHaveText(JSON.stringify(["First follow-up"]));
  await page.locator(row).getByRole("button", { name: "Edit queued message" }).click();
  await page.getByRole("button", { name: "Close chat" }).click();
  await expect(page.getByLabel("Queue state")).toHaveText("{}");
  await expect(page.getByLabel("Sent messages")).toHaveText(JSON.stringify(["First follow-up"]));
  await page.getByRole("button", { name: "Start fixture" }).click();
  await page.getByRole("button", { name: "Finish turn" }).click();
  await expect(page.getByLabel("Sent messages")).toHaveText(JSON.stringify(["First follow-up"]));
});


test("hiding and reopening a chat preserves its paused editor and unsaved draft", async ({ page }) => {
  await page.locator(row).getByRole("button", { name: "Edit queued message" }).click();
  const revised = `Keep this unsaved explanation\n${image}`;
  await page.getByRole("textbox", { name: "Edit queued message" }).fill(revised);
  // Unmount the queue like ordinary tab navigation or split zoom does.
  await page.getByRole("button", { name: "Hide chat" }).click();
  await expect(page.getByRole("textbox", { name: "Edit queued message" })).toHaveCount(0);
  await page.getByRole("button", { name: "Finish turn" }).click();
  await expect(page.getByLabel("Sent messages")).toHaveText("[]");
  await page.getByRole("button", { name: "Return to chat" }).click();
  await expect(page.getByRole("textbox", { name: "Edit queued message" })).toHaveValue(revised);
  // A second hide after the turn ended must still not send the saved original.
  await page.getByRole("button", { name: "Hide chat" }).click();
  await expect(page.getByLabel("Sent messages")).toHaveText("[]");
  await page.getByRole("button", { name: "Return to chat" }).click();
  await expect(page.getByRole("textbox", { name: "Edit queued message" })).toHaveValue(revised);
  await page.getByRole("button", { name: "Save queued message" }).click();
  await page.getByRole("button", { name: "Finish turn" }).click();
  await expect(page.getByLabel("Sent messages")).toHaveText(JSON.stringify(["First follow-up", revised]));
  await expect(page.getByLabel("Queue state")).toHaveText("{}");
});

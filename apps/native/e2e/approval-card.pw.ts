import { expect, test } from "@playwright/test";

const oldAutoSubmitDelay = 480;

test.beforeEach(async ({ page }) => {
  await page.goto("/visual-tests/approval");
  await expect(page.locator("[data-approval-ready]")).toHaveAttribute("data-approval-ready", "true");
});

test("a radio click waits for Send, submits the latest selection once, and ignores repeated activation", async ({ page }) => {
  const card = page.getByRole("region", { name: "Single-question approval" });
  const submissions = card.getByLabel("Single submissions");
  const pistachio = card.getByRole("button", { name: "Pistachio" });
  const mint = card.getByRole("button", { name: "Mint" });

  await pistachio.click();
  await expect(pistachio).toHaveAttribute("aria-pressed", "true");
  await page.waitForTimeout(oldAutoSubmitDelay + 150);
  await expect(submissions).toHaveText("[]");
  await expect(card.getByText("Which flavor should we ship?")).toBeVisible();

  await mint.click();
  await expect(pistachio).toHaveAttribute("aria-pressed", "false");
  await expect(mint).toHaveAttribute("aria-pressed", "true");
  await card.getByRole("button", { name: "Send" }).evaluate((button) => {
    const sendButton = button as HTMLButtonElement;
    sendButton.click();
    sendButton.click();
  });

  await expect(submissions).toHaveText(JSON.stringify(["Mint"]));
  await expect(card.getByText("Answers sent")).toBeVisible();
});

test("Enter selects first, then explicitly submits the selected radio answer", async ({ page }) => {
  const card = page.getByRole("region", { name: "Single-question approval" });
  const mint = card.getByRole("button", { name: "Mint" });
  const submissions = card.getByLabel("Single submissions");

  await mint.focus();
  await mint.press("Enter");
  await expect(mint).toHaveAttribute("aria-pressed", "true");
  await expect(submissions).toHaveText("[]");

  await mint.press("Enter");
  await expect(submissions).toHaveText(JSON.stringify(["Mint"]));
  await expect(card.getByText("Answers sent")).toBeVisible();
});

test("custom answers submit on Enter and selecting an option clears the custom value", async ({ page }) => {
  const card = page.getByRole("region", { name: "Single-question approval" });
  const custom = card.getByRole("textbox", { name: "Custom answer" });
  const submissions = card.getByLabel("Single submissions");

  await custom.fill("Seasonal special");
  await custom.press("Enter");
  await expect(submissions).toHaveText(JSON.stringify(["Seasonal special"]));

  await card.getByRole("button", { name: "Reset single approval" }).click();
  const resetCustom = card.getByRole("textbox", { name: "Custom answer" });
  await resetCustom.fill("Replace me");
  await card.getByRole("button", { name: "Vanilla" }).click();
  await expect(resetCustom).toHaveValue("");
  await card.getByRole("button", { name: "Send" }).click();
  await expect(card.getByLabel("Single submissions")).toHaveText(JSON.stringify(["Vanilla"]));
});

test("dismissing after selection cancels once and never submits later", async ({ page }) => {
  const card = page.getByRole("region", { name: "Single-question approval" });

  await card.getByRole("button", { name: "Pistachio" }).click();
  await card.getByRole("button", { name: "Dismiss" }).click();
  await expect(card.getByLabel("Single cancellations")).toHaveText("1");
  await page.waitForTimeout(oldAutoSubmitDelay + 150);
  await expect(card.getByLabel("Single submissions")).toHaveText("[]");
});

test("multi-question radio and checkbox answers require explicit progression", async ({ page }) => {
  const card = page.getByRole("region", { name: "Multi-question approval" });
  const submissions = card.getByLabel("Multi submissions");

  await card.getByRole("button", { name: "Online" }).click();
  await page.waitForTimeout(oldAutoSubmitDelay + 150);
  await expect(card.getByText("Which market should launch first?")).toBeVisible();
  await expect(submissions).toHaveText("[]");

  await card.getByRole("button", { name: "Continue" }).click();
  await expect(card.getByText("Which colors should be included?")).toBeVisible();
  await card.getByRole("button", { name: "Red" }).click();
  await card.getByRole("button", { name: "Blue" }).click();
  await card.getByRole("button", { name: "Red" }).click();
  await card.getByRole("button", { name: "Send" }).click();

  await expect(submissions).toHaveText(JSON.stringify([["Online", "Blue"]]));
});

test("Answers sent waits for acknowledgement and keeps the selection after a failed delivery", async ({ page }) => {
  const card = page.getByRole("region", { name: "Acknowledged approval" });
  const send = card.getByRole("button", { name: "Send" });
  await card.getByRole("button", { name: "Yes" }).click();
  await expect(send).toBeEnabled();
  await send.click();
  await expect(card.getByText("Sending…")).toBeVisible();
  await expect(card.getByText("Answers sent")).toHaveCount(0);
  await expect(card.getByRole("alert")).toHaveText("notify failed");
  await expect(card.getByRole("button", { name: "Yes" })).toHaveAttribute("aria-pressed", "true");
  await expect(card.getByLabel("Acknowledged submissions")).toHaveText("0");
  await card.getByRole("button", { name: "Send" }).click();
  await expect(card.getByText("Answers sent")).toBeVisible();
  await expect(card.getByLabel("Acknowledged submissions")).toHaveText("1");
});

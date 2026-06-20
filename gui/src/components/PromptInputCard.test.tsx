import { describe, expect, test } from "bun:test";
import type { ComponentProps } from "react";
import { renderToStaticMarkup } from "react-dom/server";

import type {
  CommandDescriptor,
  PromptSettings,
} from "@/services/desktop/types/contracts";
import { PromptInputCard } from "./PromptInputCard";

const longModelName =
  "claude-4.7-sonnet-super-long-context-reasoning-preview-20260615";

const promptSettings: PromptSettings = {
  availableModels: [
    {
      contextLength: 200000n,
      modelId: "claude-sonnet-long",
      modelName: longModelName,
      providerId: "anthropic",
      providerName: "Anthropic",
      reasoningEfforts: ["low", "medium", "high"],
      supportsReasoning: true,
    },
  ],
  selectedModelId: "claude-sonnet-long",
  selectedProviderId: "anthropic",
  selectedReasoningEffort: "medium",
  fastEnabled: false,
  fastApplies: false,
};

function renderPromptInputCard(
  overrides: Partial<ComponentProps<typeof PromptInputCard>> = {},
) {
  return renderToStaticMarkup(
    <PromptInputCard
      canCompose
      isPlanningMode={false}
      isRequestActive={false}
      isSendingPrompt={false}
      onCommandSelect={(_: CommandDescriptor) => {}}
      promptDraft="Describe this repo"
      promptSettings={promptSettings}
      setPlanningMode={() => {}}
      setPromptDraft={() => {}}
      stopPrompt={async () => {}}
      submitPrompt={async () => {}}
      updatePromptSettings={async () => {}}
      workspacePath="/workspace/codegraff"
      {...overrides}
    />,
  );
}

describe("PromptInputCard", () => {
  test("constrains long selected model names in the footer", () => {
    const html = renderPromptInputCard();

    expect(html).toContain("max-w-44");
    expect(html).toContain("truncate");
    expect(html).toContain(`title="${longModelName}"`);
  });

  test("keeps the textarea editable and send-enabled for queued follow-ups", () => {
    const html = renderPromptInputCard({ isRequestActive: true });

    expect(html).toContain("Queue a follow-up…");
    expect(html).toContain('aria-label="Send"');
    expect(html).not.toContain("<textarea disabled");
  });

  test("keeps stop available while running with an empty draft", () => {
    const html = renderPromptInputCard({
      isRequestActive: true,
      promptDraft: "",
    });

    expect(html).toContain('aria-label="Stop"');
  });
});

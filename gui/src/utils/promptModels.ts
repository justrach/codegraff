import type {
  PromptModelOption,
  PromptSettings,
} from "@/services/desktop/types/contracts";

export const DEFAULT_REASONING_EFFORT = "medium";

export function getPromptModelValue(
  model: Pick<PromptModelOption, "providerId" | "modelId">,
): string {
  return `${model.providerId}:${model.modelId}`;
}

export function findSelectedPromptModel(
  promptSettings: PromptSettings | null,
): PromptModelOption | null {
  if (promptSettings == null) {
    return null;
  }

  return (
    promptSettings.availableModels.find(
      (model) =>
        model.providerId === promptSettings.selectedProviderId &&
        model.modelId === promptSettings.selectedModelId,
    ) ?? null
  );
}

export function resolveSelectedPromptReasoning(
  model: PromptModelOption | null,
  selectedReasoningEffort: string | null | undefined,
): string | null {
  if (model == null) {
    return null;
  }

  if (
    selectedReasoningEffort != null &&
    model.reasoningEfforts.includes(selectedReasoningEffort)
  ) {
    return selectedReasoningEffort;
  }

  return getDefaultPromptReasoningEffort(model);
}

export function filterPromptModels(
  availableModels: PromptModelOption[] | null | undefined,
  searchQuery: string,
): PromptModelOption[] {
  const normalizedSearchQuery = searchQuery.trim().toLowerCase();
  const models = availableModels ?? [];

  if (normalizedSearchQuery.length === 0) {
    return models;
  }

  return models.filter((model) => {
    const searchableText = [
      model.modelName,
      model.modelId,
      model.providerName,
      model.providerId,
    ]
      .filter(Boolean)
      .join(" ")
      .toLowerCase();

    return searchableText.includes(normalizedSearchQuery);
  });
}

export function findPromptModelByValue(
  availableModels: PromptModelOption[] | null | undefined,
  value: string,
): PromptModelOption | null {
  return (
    (availableModels ?? []).find(
      (model) => getPromptModelValue(model) === value,
    ) ?? null
  );
}

export function getNextPromptReasoningEffort(
  model: PromptModelOption,
  selectedReasoning: string | null,
): string | null {
  return selectedReasoning != null &&
    model.reasoningEfforts.includes(selectedReasoning)
    ? selectedReasoning
    : getDefaultPromptReasoningEffort(model);
}

export function getDefaultPromptReasoningEffort(
  model: PromptModelOption,
): string | null {
  if (model.reasoningEfforts.length === 0) {
    return null;
  }

  return model.reasoningEfforts.includes(DEFAULT_REASONING_EFFORT)
    ? DEFAULT_REASONING_EFFORT
    : model.reasoningEfforts[0];
}

import { useState } from "react";

import type { UsePromptModelPickerOptions } from "./types/prompt";
import {
  filterPromptModels,
  findPromptModelByValue,
  findSelectedPromptModel,
  getNextPromptReasoningEffort,
  getPromptModelValue,
  resolveSelectedPromptReasoning,
} from "@/utils/promptModels";

export function usePromptModelPicker({
  promptSettings,
  updatePromptSettings,
}: UsePromptModelPickerOptions) {
  const [isModelMenuOpen, setIsModelMenuOpen] = useState(false);
  const [modelSearchQuery, setModelSearchQuery] = useState("");
  const availableModels = promptSettings?.availableModels ?? [];
  const selectedModel = findSelectedPromptModel(promptSettings);
  const selectedReasoningEfforts = selectedModel?.reasoningEfforts ?? [];
  const selectedReasoning = resolveSelectedPromptReasoning(
    selectedModel,
    promptSettings?.selectedReasoningEffort,
  );
  const visibleModels = filterPromptModels(availableModels, modelSearchQuery);

  function handleModelMenuOpenChange(open: boolean) {
    setIsModelMenuOpen(open);
    if (!open) {
      setModelSearchQuery("");
    }
  }

  function handleModelChange(value: string) {
    const nextModel = findPromptModelByValue(availableModels, value);
    if (nextModel == null) {
      return;
    }

    void updatePromptSettings({
      providerId: nextModel.providerId,
      modelId: nextModel.modelId,
      reasoningEffort: getNextPromptReasoningEffort(
        nextModel,
        selectedReasoning,
      ),
    });
    setIsModelMenuOpen(false);
    setModelSearchQuery("");
  }

  function handleReasoningChange(value: string) {
    if (selectedModel == null) {
      return;
    }

    void updatePromptSettings({
      providerId: selectedModel.providerId,
      modelId: selectedModel.modelId,
      reasoningEffort: value,
    });
  }

  return {
    handleModelChange,
    handleModelMenuOpenChange,
    handleReasoningChange,
    hasAvailableModels: availableModels.length > 0,
    isModelMenuOpen,
    modelSearchQuery,
    selectedModel,
    selectedModelValue:
      selectedModel == null ? "" : getPromptModelValue(selectedModel),
    selectedReasoning,
    selectedReasoningEfforts,
    setModelSearchQuery,
    visibleModels,
  };
}

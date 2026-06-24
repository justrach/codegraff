import { useEffect, useRef, useState } from "react";

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
  const [optimisticSelectedModelValue, setOptimisticSelectedModelValue] =
    useState<string | null>(null);
  const lastRequestedModelValueRef = useRef<string | null>(null);
  const modelRequestSeqRef = useRef(0);
  const availableModels = promptSettings?.availableModels ?? [];
  const actualSelectedModel = findSelectedPromptModel(promptSettings);
  const actualSelectedModelValue =
    actualSelectedModel == null ? "" : getPromptModelValue(actualSelectedModel);
  const optimisticSelectedModel =
    optimisticSelectedModelValue == null
      ? null
      : findPromptModelByValue(availableModels, optimisticSelectedModelValue);
  const selectedModel = optimisticSelectedModel ?? actualSelectedModel;
  const selectedModelValue =
    selectedModel == null ? "" : getPromptModelValue(selectedModel);
  const selectedReasoningEfforts = selectedModel?.reasoningEfforts ?? [];
  const selectedReasoning = resolveSelectedPromptReasoning(
    selectedModel,
    promptSettings?.selectedReasoningEffort,
  );
  const visibleModels = filterPromptModels(availableModels, modelSearchQuery);

  useEffect(() => {
    if (
      optimisticSelectedModelValue != null &&
      optimisticSelectedModelValue === actualSelectedModelValue
    ) {
      setOptimisticSelectedModelValue(null);
      lastRequestedModelValueRef.current = null;
    }
  }, [actualSelectedModelValue, optimisticSelectedModelValue]);

  function handleModelMenuOpenChange(open: boolean) {
    setIsModelMenuOpen(open);
    if (!open) {
      setModelSearchQuery("");
    }
  }

  function handleModelChange(value: string) {
    if (
      value === lastRequestedModelValueRef.current ||
      (value === actualSelectedModelValue &&
        lastRequestedModelValueRef.current == null)
    ) {
      setIsModelMenuOpen(false);
      setModelSearchQuery("");
      return;
    }

    const nextModel = findPromptModelByValue(availableModels, value);
    if (nextModel == null) {
      return;
    }

    const requestSeq = modelRequestSeqRef.current + 1;
    modelRequestSeqRef.current = requestSeq;
    lastRequestedModelValueRef.current = value;
    setOptimisticSelectedModelValue(value);
    setIsModelMenuOpen(false);
    setModelSearchQuery("");
    void updatePromptSettings({
      providerId: nextModel.providerId,
      modelId: nextModel.modelId,
      reasoningEffort: getNextPromptReasoningEffort(
        nextModel,
        selectedReasoning,
      ),
    })
      .then(() => {
        window.setTimeout(() => {
          if (
            modelRequestSeqRef.current === requestSeq &&
            lastRequestedModelValueRef.current === value
          ) {
            lastRequestedModelValueRef.current = null;
            setOptimisticSelectedModelValue(null);
          }
        }, 1000);
      })
      .catch(() => {
        if (
          modelRequestSeqRef.current === requestSeq &&
          lastRequestedModelValueRef.current === value
        ) {
          lastRequestedModelValueRef.current = null;
          setOptimisticSelectedModelValue(null);
        }
      });
  }

  function handleReasoningChange(value: string) {
    if (selectedModel == null) {
      return;
    }

    void updatePromptSettings({
      providerId: selectedModel.providerId,
      modelId: selectedModel.modelId,
      reasoningEffort: value,
    }).catch(() => undefined);
  }

  return {
    handleModelChange,
    handleModelMenuOpenChange,
    handleReasoningChange,
    hasAvailableModels: availableModels.length > 0,
    isModelMenuOpen,
    modelSearchQuery,
    selectedModel,
    selectedModelValue,
    selectedReasoning,
    selectedReasoningEfforts,
    setModelSearchQuery,
    visibleModels,
  };
}

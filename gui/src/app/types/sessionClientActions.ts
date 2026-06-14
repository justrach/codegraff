export interface FollowupResponseInput {
  cancelled: boolean;
  followupId: string;
  text?: string;
  selectedOptionIds?: string[];
}

export interface WorkspacePromptSettingsUpdateInput {
  providerId: string;
  modelId: string;
  reasoningEffort?: string | null;
}

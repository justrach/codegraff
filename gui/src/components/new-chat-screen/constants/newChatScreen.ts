import type {
  CloneFormState,
  QuickStartFormState,
} from "../types/newChatScreen";

export const REPOSITORY_NAME_PATTERN = /^[A-Za-z0-9._-]+$/;

export const initialCloneFormState: CloneFormState = {
  repositoryUrl: "",
  parentDirectory: "",
  directoryName: "",
};

export const initialQuickStartFormState: QuickStartFormState = {
  projectName: "",
  parentDirectory: "",
  visibility: "private",
};

import { useState, type FormEvent } from "react";

import { useSessionActions } from "@/hooks/useSession";
import * as desktopClient from "@/services/desktop/client";
import { formatError } from "@/utils/errors";

import {
  REPOSITORY_NAME_PATTERN,
  initialCloneFormState,
  initialQuickStartFormState,
} from "../constants/newChatScreen";
import { deriveDirectoryNameFromRepositoryUrl } from "../utils/projectSetup";
import type {
  NewChatScreenControllerProps,
  PendingAction,
  QuickStartFormState,
} from "../types/newChatScreen";

export function useNewChatScreenController({
  isOpeningProject,
  uiError,
}: NewChatScreenControllerProps) {
  const { openProject, openWorkspacePicker } = useSessionActions();
  const [cloneDialogOpen, setCloneDialogOpen] = useState(false);
  const [quickStartDialogOpen, setQuickStartDialogOpen] = useState(false);
  const [cloneForm, setCloneForm] = useState(initialCloneFormState);
  const [quickStartForm, setQuickStartForm] = useState(
    initialQuickStartFormState,
  );
  const [cloneDirectoryManuallyEdited, setCloneDirectoryManuallyEdited] =
    useState(false);
  const [pendingAction, setPendingAction] = useState<PendingAction>(null);
  const [actionError, setActionError] = useState<string | null>(null);

  const isBusy = isOpeningProject || pendingAction != null;
  const visibleError = actionError ?? uiError;
  const cloneFormValid =
    cloneForm.repositoryUrl.trim().length > 0 &&
    cloneForm.parentDirectory.trim().length > 0 &&
    REPOSITORY_NAME_PATTERN.test(cloneForm.directoryName.trim());
  const quickStartFormValid =
    REPOSITORY_NAME_PATTERN.test(quickStartForm.projectName.trim()) &&
    quickStartForm.parentDirectory.trim().length > 0;

  function resetCloneForm() {
    setCloneForm(initialCloneFormState);
    setCloneDirectoryManuallyEdited(false);
  }

  function resetQuickStartForm() {
    setQuickStartForm(initialQuickStartFormState);
  }

  function clearActionError() {
    setActionError(null);
  }

  function openCloneDialog() {
    clearActionError();
    setCloneDialogOpen(true);
  }

  function openQuickStartDialog() {
    clearActionError();
    setQuickStartDialogOpen(true);
  }

  function handleCloneDialogChange(open: boolean) {
    if (pendingAction != null) {
      return;
    }

    setCloneDialogOpen(open);
    if (open === false) {
      resetCloneForm();
    }
  }

  function handleQuickStartDialogChange(open: boolean) {
    if (pendingAction != null) {
      return;
    }

    setQuickStartDialogOpen(open);
    if (open === false) {
      resetQuickStartForm();
    }
  }

  function handleCloneRepositoryUrlChange(value: string) {
    setCloneForm((current) => {
      const nextDerivedName = deriveDirectoryNameFromRepositoryUrl(value);
      const previousDerivedName = deriveDirectoryNameFromRepositoryUrl(
        current.repositoryUrl,
      );
      const shouldSyncDirectoryName =
        cloneDirectoryManuallyEdited === false ||
        current.directoryName.trim().length === 0 ||
        current.directoryName === previousDerivedName;

      return {
        ...current,
        repositoryUrl: value,
        directoryName: shouldSyncDirectoryName
          ? nextDerivedName
          : current.directoryName,
      };
    });
  }

  function handleCloneParentDirectoryChange(value: string) {
    setCloneForm((current) => ({
      ...current,
      parentDirectory: value,
    }));
  }

  function handleCloneDirectoryNameChange(value: string) {
    setCloneDirectoryManuallyEdited(true);
    setCloneForm((current) => ({
      ...current,
      directoryName: value,
    }));
  }

  function handleQuickStartProjectNameChange(value: string) {
    setQuickStartForm((current) => ({
      ...current,
      projectName: value,
    }));
  }

  function handleQuickStartParentDirectoryChange(value: string) {
    setQuickStartForm((current) => ({
      ...current,
      parentDirectory: value,
    }));
  }

  function handleQuickStartVisibilityChange(
    visibility: QuickStartFormState["visibility"],
  ) {
    setQuickStartForm((current) => ({
      ...current,
      visibility,
    }));
  }

  async function pickDirectory(
    title: string,
    onSelect: (parentDirectory: string) => void,
  ) {
    clearActionError();
    const parentDirectory = await desktopClient.pickDirectory(title).catch(
      (error) => {
        setActionError(formatError(error));
        return null;
      },
    );

    if (parentDirectory != null) {
      onSelect(parentDirectory);
    }
  }

  async function handleCloneDestinationPick() {
    await pickDirectory(
      "Choose a folder for the cloned repository",
      handleCloneParentDirectoryChange,
    );
  }

  async function handleQuickStartDestinationPick() {
    await pickDirectory(
      "Choose a folder for the new GitHub project",
      handleQuickStartParentDirectoryChange,
    );
  }

  async function runWorkspaceSetupAction(
    action: Exclude<PendingAction, null>,
    operation: () => Promise<string | null>,
    onSuccess: () => void,
  ) {
    clearActionError();
    setPendingAction(action);

    const workspacePath = await operation();
    if (workspacePath != null) {
      await openProject(workspacePath);
      onSuccess();
    }

    setPendingAction(null);
  }

  async function handleCloneSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (cloneFormValid === false || isBusy) {
      return;
    }

    await runWorkspaceSetupAction(
      "clone",
      async () =>
        await desktopClient
          .cloneRepository({
            repositoryUrl: cloneForm.repositoryUrl.trim(),
            parentDirectory: cloneForm.parentDirectory.trim(),
            directoryName: cloneForm.directoryName.trim(),
          })
          .catch((error) => {
            setActionError(formatError(error));
            return null;
          }),
      () => {
        setCloneDialogOpen(false);
        resetCloneForm();
      },
    );
  }

  async function handleQuickStartSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (quickStartFormValid === false || isBusy) {
      return;
    }

    await runWorkspaceSetupAction(
      "quick-start",
      async () =>
        await desktopClient
          .quickStartProject({
            projectName: quickStartForm.projectName.trim(),
            parentDirectory: quickStartForm.parentDirectory.trim(),
            visibility: quickStartForm.visibility,
          })
          .catch((error) => {
            setActionError(formatError(error));
            return null;
          }),
      () => {
        setQuickStartDialogOpen(false);
        resetQuickStartForm();
      },
    );
  }

  async function handleOpenWorkspacePicker() {
    clearActionError();
    if (!desktopClient.isNativeBridgeAvailable()) {
      setActionError(
        "Opening a local folder requires the Codegraff desktop app. In this browser preview, use Clone from Git or Quick start to inspect the setup flow.",
      );
      return;
    }
    await openWorkspacePicker();
  }

  return {
    cloneDialogOpen,
    cloneForm,
    cloneFormValid,
    handleCloneDestinationPick,
    handleCloneDirectoryNameChange,
    handleCloneDialogChange,
    handleCloneParentDirectoryChange,
    handleCloneRepositoryUrlChange,
    handleCloneSubmit,
    handleOpenWorkspacePicker,
    handleQuickStartDestinationPick,
    handleQuickStartDialogChange,
    handleQuickStartParentDirectoryChange,
    handleQuickStartProjectNameChange,
    handleQuickStartSubmit,
    handleQuickStartVisibilityChange,
    isBusy,
    openCloneDialog,
    openQuickStartDialog,
    pendingAction,
    quickStartDialogOpen,
    quickStartForm,
    quickStartFormValid,
    visibleError,
  };
}

export interface ActivityDisclosureState {
  isOpen: boolean;
  observedRunning: boolean;
}

interface ActivityDisclosureInput {
  hasError: boolean;
  isRunning: boolean;
  isThinking: boolean;
}

export function createActivityDisclosureState(
  input: ActivityDisclosureInput,
): ActivityDisclosureState {
  return {
    isOpen: input.isThinking || input.isRunning || input.hasError,
    observedRunning: input.isRunning,
  };
}

export function reconcileActivityDisclosure(
  state: ActivityDisclosureState,
  input: ActivityDisclosureInput,
): ActivityDisclosureState {
  if (
    input.isThinking ||
    state.observedRunning === input.isRunning
  ) {
    return state;
  }

  return {
    isOpen:
      input.isRunning || input.hasError ? true : state.isOpen,
    observedRunning: input.isRunning,
  };
}

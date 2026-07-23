import { describe, expect, test } from "bun:test";

import {
  createActivityDisclosureState,
  reconcileActivityDisclosure,
} from "./chatActivityDisclosure";

describe("activity disclosure transitions", () => {
  test("opens when an idle activity starts running", () => {
    const idle = createActivityDisclosureState({
      hasError: false,
      isRunning: false,
      isThinking: false,
    });

    expect(
      reconcileActivityDisclosure(idle, {
        hasError: false,
        isRunning: true,
        isThinking: false,
      }),
    ).toEqual({
      isOpen: true,
      observedRunning: true,
    });
  });

  test("preserves the user's disclosure state after successful completion", () => {
    const runningButClosed = {
      isOpen: false,
      observedRunning: true,
    };

    expect(
      reconcileActivityDisclosure(runningButClosed, {
        hasError: false,
        isRunning: false,
        isThinking: false,
      }),
    ).toEqual({
      isOpen: false,
      observedRunning: false,
    });
  });

  test("forces a failed completion open", () => {
    expect(
      reconcileActivityDisclosure(
        {
          isOpen: false,
          observedRunning: true,
        },
        {
          hasError: true,
          isRunning: false,
          isThinking: false,
        },
      ),
    ).toEqual({
      isOpen: true,
      observedRunning: false,
    });
  });

  test("returns the same state when no stream transition occurred", () => {
    const state = {
      isOpen: true,
      observedRunning: false,
    };

    expect(
      reconcileActivityDisclosure(state, {
        hasError: false,
        isRunning: false,
        isThinking: false,
      }),
    ).toBe(state);
  });
});

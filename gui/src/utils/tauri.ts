type TauriWindow = Window & {
  __TAURI_INTERNALS__?: unknown;
};

export function hasTauriInternals(): boolean {
  return typeof (window as TauriWindow).__TAURI_INTERNALS__ === "object";
}

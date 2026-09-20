/** A composer menu row is keyboard-activatable only after the user has
 * visibly selected it by hovering or using the arrow keys. */
export function shouldPickComposerRow(key: string, shiftKey: boolean, engaged: boolean): boolean {
  return engaged && !shiftKey && (key === "Enter" || key === "Tab");
}

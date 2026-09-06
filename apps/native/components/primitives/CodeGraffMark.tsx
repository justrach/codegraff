/** The compact ink-circle/code mark inherits the active theme's ink color. */
export default function CodeGraffMark({ size = 20 }: { size?: number }) {
  return <svg data-codegraff-mark aria-hidden="true" width={size} height={size} viewBox="0 0 32 32" fill="none">
    <use href="/codegraff-mark.svg#mark" />
  </svg>;
}

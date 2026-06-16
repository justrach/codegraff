import type { ChatStatusLabelProps } from "./types/chatComponents";

export function ChatStatusLabel({
  active = false,
  text,
}: ChatStatusLabelProps) {
  const firstSpaceIndex = text.indexOf(" ");
  const activeWord =
    firstSpaceIndex === -1 ? text : text.slice(0, firstSpaceIndex);
  const remainder = firstSpaceIndex === -1 ? "" : text.slice(firstSpaceIndex);

  return (
    <span>
      <span
        className={
          active
            ? "shimmer shimmer-invert shimmer-repeat-delay-0"
            : undefined
        }
      >
        {activeWord}
      </span>
      {remainder}
    </span>
  );
}

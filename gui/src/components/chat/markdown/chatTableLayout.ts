const MIN_COLUMN_WIDTH_PX = 96;

export type ChatTableLayout = "table" | "records";

export function chatTableLayoutFor(
  containerWidthPx: number,
  columnCount: number,
): ChatTableLayout {
  return (
    containerWidthPx > 0 &&
    containerWidthPx < columnCount * MIN_COLUMN_WIDTH_PX
  )
    ? "records"
    : "table";
}

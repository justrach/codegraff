/** How close to the tail counts as "still following". A large slack (the old
 * 240px magnet) made it impossible to scroll away while tokens arrived. */
export const TAIL_SLACK_PX = 48;

export function distanceFromTail(el: {
  scrollHeight: number;
  scrollTop: number;
  clientHeight: number;
}): number {
  return el.scrollHeight - el.scrollTop - el.clientHeight;
}

export function isFollowingTail(
  el: { scrollHeight: number; scrollTop: number; clientHeight: number },
  slack = TAIL_SLACK_PX,
): boolean {
  return distanceFromTail(el) <= slack;
}

/** Content growth can move the tail without the reader scrolling away. */
export function followsAfterScroll(el: { scrollHeight: number; scrollTop: number; clientHeight: number }, previousTop: number, wasFollowing: boolean): boolean {
  return isFollowingTail(el) || wasFollowing && el.scrollTop >= previousTop;
}

/** Pin only while the reader is following. WKWebView treats scrollIntoView
 * on a tall article as a viewport realignment every frame. */
export function pinScrollerTail(el: HTMLElement | null, following: boolean): void {
  if (!el || !following) return;
  el.scrollTop = el.scrollHeight;
}

/** Bottom padding so the last transcript line sits above a floating composer. */
export function overlayClearancePx(overlayHeight: number, slack = 12, floor = 144): number {
  if (!Number.isFinite(overlayHeight) || overlayHeight < 0) return floor;
  return Math.max(floor, Math.ceil(overlayHeight + slack));
}
